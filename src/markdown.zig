//! markdown.zig — Markdown to styled rows for a terminal chat surface,
//! with the untrusted-input sanitiser this module exists for.
//!
//! Scope is the subset a chat transcript needs and nothing more:
//! paragraphs, ATX headings (`#`..`######`), unordered and ordered lists
//! nested by indentation, fenced code blocks (the info string stays on
//! `Line.lang` for a caller-supplied highlighter), inline code, bold,
//! italic, strikethrough, and links. Links never resolve: `Span.url`
//! records the target for the caller and nothing here follows, opens or
//! fetches it.
//!
//! The sanitiser is the point. Model output is untrusted bytes, and a
//! control byte that reaches a cell buffer becomes a terminal command.
//! `Sanitizer` holds the one escape machine every caller shares: its
//! `accept(cp)` and `acceptCluster(gc)` are allocation-free verdicts for
//! a draw-path caller, and `sanitize` is the copying form. It drops every
//! control codepoint except tab and newline (C0 minus tab/newline, DEL,
//! and encoded C1) and consumes whole escape sequences — ESC
//! introducers, CSI, and the OSC/DCS/APC/SOS/PM string families in both
//! 7-bit and 8-bit C1 form — before any byte reaches a `Span`. Escape
//! state persists across line breaks, so a sequence split over two lines
//! is still consumed. Tab and newline are structure: they pass in every
//! state and only steer the machine. A string sequence ends on its own
//! terminator only — ST for all five families, BEL for OSC as well — so
//! an ESC continuation that is not `\` stays inside the string and a
//! fragmented or unterminated one leaks nothing.
//!
//! Allocation is explicit: `Renderer` owns one arena built on the
//! allocator passed to `init`; `render` allocates only there. Every
//! slice in a returned `Block` borrows that arena and stays valid until
//! the next `render` call or `deinit`.
//!
//! Width and grapheme knowledge come from `width.zig` only
//! (`strWidth`, `graphemeWidth`, `firstGraphemeLen`); this file must not
//! import zg (plan §0 grep-gate).

const std = @import("std");
const Color = @import("color.zig").Color;
const Style = @import("style.zig").Style;
const Width = @import("width.zig");

/// Errors this module can produce: arena allocation failure only.
pub const Error = error{OutOfMemory};

/// One styled run of text. `text` borrows the renderer arena. `url` is
/// set only on link text; it is metadata, never followed or fetched.
pub const Span = struct {
    text: []const u8,
    style: Style = .{},
    url: ?[]const u8 = null,
};

/// Block role of a rendered line.
pub const Kind = enum { paragraph, heading, list_item, code, blank };

/// One rendered row. A wrapped source construct yields several `Line`s
/// that share `kind`, `indent` and `lang`.
pub const Line = struct {
    /// Styled runs, left to right. Mutable so a `Highlighter` can restyle
    /// a code row in place; the bytes still borrow the arena.
    spans: []Span,
    kind: Kind = .paragraph,
    /// ATX level 1..6 when `kind == .heading`, else 0.
    level: u8 = 0,
    /// List nesting depth when `kind == .list_item` (leading spaces /
    /// `Options.indent_width`), else 0.
    indent: u8 = 0,
    /// True when the item came from an ordered (`1.` / `1)`) marker.
    ordered: bool = false,
    /// Fence info string when `kind == .code`, else "".
    lang: []const u8 = "",
};

/// A rendered document: lines top to bottom.
pub const Block = struct {
    lines: []const Line,
};

/// Called once per complete fenced code block after its lines are
/// rendered, with the fence's info string (`lang`). The hook may restyle
/// or replace any `lines[i].spans`; `arena` backs new text. An
/// unterminated (malformed) fence still calls it when it produced lines.
pub const Highlighter = *const fn (
    arena: std.mem.Allocator,
    ctx: ?*anyopaque,
    lang: []const u8,
    lines: []Line,
) Error!void;

/// Rendering knobs. Defaults render unwrapped, tab-expanded text with
/// attributes only (no colors): the caller's theme supplies colors.
pub const Options = struct {
    /// Wrap column in terminal cells; 0 disables wrapping.
    width: usize = 0,
    /// Hard-tab stop, in cells.
    tab_width: usize = 4,
    /// Source spaces per list nesting level.
    indent_width: usize = 2,
    /// Merged under every heading run (bold is always added).
    heading: Style = .{},
    /// Merged under code runs, fenced and inline.
    code: Style = .{},
    /// Style for list markers.
    marker: Style = .{},
    /// Merged under link text.
    link: Style = .{ .attrs = .{ .underline = true } },
    highlighter: ?Highlighter = null,
    highlighter_ctx: ?*anyopaque = null,
};

/// Control codepoints that must never reach a `Span`: C0 (tab and
/// newline are handled separately and pass), DEL, and encoded C1.
fn isForbidden(cp: u21) bool {
    return cp < 0x20 or cp == 0x7F or (cp >= 0x80 and cp <= 0x9F);
}

/// The terminal-input filter: one escape machine, four entry points.
///
/// - `accept(cp)` — allocation-free, one decoded codepoint in, one
///   keep/drop verdict out. This is the whole rule for a draw-path
///   caller (a pen with no allocator, a scanner): it holds a `Sanitizer`
///   on the stack and drops whatever `accept` refuses.
/// - `acceptCluster(gc)` — the same rule at grapheme granularity: a
///   cluster survives whole or not at all, and the machine advances
///   either way, so an escape sequence spread over several clusters
///   (ESC, '[', parameters, final byte) still consumes as one.
/// - `copy(out, src)` — the one scanning loop: `src` filtered into a
///   buffer the caller already owns, in a single pass with no
///   temporary. `out` needs `src.len` bytes, because filtering only
///   removes, and must not overlap `src`.
/// - `sanitize(allocator, src)` — `copy` plus the allocation that
///   produces the buffer, for callers that want a filtered string.
///
/// Tab and newline are structure: they pass in every state, so a line
/// break never hides from the filter, and only the machine moves. Every
/// other control, and every byte of an escape sequence body, is
/// consumed: ESC introducers, CSI, and the OSC/DCS/APC/SOS/PM families
/// in both 7-bit and 8-bit C1 form. A string sequence ends only on its
/// own terminator — ST (7-bit `ESC \` or 8-bit 0x9C) for all five
/// families, and BEL for OSC as well. An ESC inside a string ends it
/// only when `\` follows; any other continuation returns to the same
/// string, so `ESC ] 0;title ESC <tab> payload` keeps consuming.
/// Escape state carries across calls and across line breaks, so a
/// sequence split over two chunks is consumed as one. Input that ends
/// inside a sequence fails closed: the machine stays armed and the
/// remainder of a later chunk is consumed instead of leaking. Invalid
/// UTF-8 is dropped everywhere, identically in every entry point.
pub const Sanitizer = struct {
    state: State = .ground,

    const State = enum { ground, escape, csi, string, string_esc, osc, osc_esc };

    /// Filter `src` into `out`, which must hold `src.len` bytes, and
    /// return the length written. The one scanning loop: single pass,
    /// no temporary, no regrowth. `out` must not overlap `src`.
    pub fn copy(self: *Sanitizer, out: []u8, src: []const u8) usize {
        var i: usize = 0;
        var n: usize = 0;
        while (i < src.len) {
            const len: usize = std.unicode.utf8ByteSequenceLength(src[i]) catch {
                i += 1; // stray continuation or invalid lead: drop one byte
                continue;
            };
            if (len > src.len - i) break; // truncated tail: nothing valid left
            const cp = decodeSeq(src, i, len) orelse {
                i += 1;
                continue;
            };
            i += len;
            if (!self.accept(cp)) continue;
            var buf: [4]u8 = undefined;
            const enc = if (len == 1) blk: {
                buf[0] = src[i - 1]; // ASCII: the source byte is its encoding
                break :blk 1;
            } else encodeInto(&buf, cp);
            if (enc == 0) continue;
            @memcpy(out[n..][0..enc], buf[0..enc]);
            n += enc;
        }
        return n;
    }

    /// Strip `src`, returning a slice the caller owns (free with the
    /// same allocator). Invalid UTF-8 bytes are dropped.
    pub fn sanitize(self: *Sanitizer, allocator: std.mem.Allocator, src: []const u8) Error![]u8 {
        const buf = try allocator.alloc(u8, src.len);
        errdefer allocator.free(buf);
        const n = self.copy(buf, src);
        // Handing back the exact length needs no second copy when it
        // fails; the over-long buffer is still ours and still valid.
        return allocator.realloc(buf, n) catch buf[0..n];
    }

    /// Feed one decoded codepoint and report whether it survives.
    ///
    /// Allocation-free: the escape machine is the only state, so this is
    /// the whole sanitiser for a caller that filters where it draws (a
    /// pen with no allocator, a scanner) — decode codepoints, drop what
    /// this returns false for. Returns true only for tab, newline and
    /// non-control scalars; every escape-sequence byte and every other
    /// control is consumed.
    pub fn accept(self: *Sanitizer, cp: u21) bool {
        // Tab and newline are structure: they pass in every state, so a
        // line break never hides from the filter. Every other scalar
        // passes only in ground, which is what consumes a sequence body.
        const keep = if (cp == '\n' or cp == '\t')
            true
        else
            self.state == .ground and !isForbidden(cp);
        self.step(cp);
        return keep;
    }

    /// Whether the grapheme cluster `gc` survives the filter whole.
    ///
    /// A cluster is kept only when every codepoint in it survives, so a
    /// combining mark is never split off its base. The machine always
    /// advances, dropped cluster or not: that is what makes an escape
    /// sequence spanning several clusters (ESC, '[', parameters, final
    /// byte) consume as one, exactly as the copying form does. Invalid
    /// UTF-8 is dropped and leaves the machine untouched, matching
    /// `sanitize`.
    pub fn acceptCluster(self: *Sanitizer, gc: []const u8) bool {
        var keep = true;
        var i: usize = 0;
        while (i < gc.len) {
            const len: usize = std.unicode.utf8ByteSequenceLength(gc[i]) catch {
                keep = false;
                break;
            };
            if (len > gc.len - i) {
                keep = false;
                break;
            }
            const cp = decodeSeq(gc, i, len) orelse {
                keep = false;
                break;
            };
            i += len;
            if (!self.accept(cp)) keep = false;
        }
        return keep;
    }

    /// Advance the escape state machine over `cp`, consuming the byte.
    fn step(self: *Sanitizer, cp: u21) void {
        switch (self.state) {
            .ground => switch (cp) {
                '\n', '\t' => {}, // structure: passes, grounds nothing
                0x1B => self.state = .escape,
                0x9B => self.state = .csi,
                0x9D => self.state = .osc, // BEL terminates OSC
                0x90, 0x98, 0x9E, 0x9F => self.state = .string,
                else => {},
            },
            .escape => switch (cp) {
                '\n', '\t' => self.state = .ground, // broken escape, real break
                0x1B => {}, // ESC ESC: stay armed
                '[' => self.state = .csi,
                ']' => self.state = .osc,
                'P', 'X', '^', '_' => self.state = .string,
                else => self.state = .ground, // one-byte escape: body dropped
            },
            .csi => switch (cp) {
                // A control inside CSI does not cancel it (ECMA-48); the
                // line break is real, the sequence keeps consuming.
                '\n', '\t' => {},
                0x1B => self.state = .escape,
                else => if (cp >= 0x40 and cp <= 0x7E) {
                    self.state = .ground; // final byte: sequence complete
                },
            },
            .string => switch (cp) {
                0x1B => self.state = .string_esc,
                0x9C => self.state = .ground, // ST, 8-bit spelling
                '\n', '\t' => {}, // structure passes; the string keeps eating
                else => {}, // string payload: consumed
            },
            .string_esc => switch (cp) {
                '\\' => self.state = .ground, // ST: the string ends here
                0x1B => {}, // ESC ESC: still inside the string
                // Any other continuation is not a terminator, so the
                // machine goes back to the string it was eating and
                // the payload stays consumed. Falling to ground here
                // is what let `ESC ] 0;title ESC <tab> payload` leak.
                else => self.state = .string,
            },
            .osc => switch (cp) {
                0x1B => self.state = .osc_esc,
                0x07, 0x9C => self.state = .ground, // BEL or ST ends OSC
                '\n', '\t' => {},
                else => {},
            },
            .osc_esc => switch (cp) {
                '\\' => self.state = .ground,
                0x1B => {},
                else => self.state = .osc, // same rule, same family
            },
        }
    }
};

/// The codepoint encoded in the `len` bytes at `bytes[i..]`, or null when
/// those bytes are not a well-formed sequence of that width.
///
/// `len` is the `utf8ByteSequenceLength` of the lead byte and the caller
/// has already checked that many bytes are there, so the width-specific
/// decoders are exact: they reject a malformed body and nothing else.
/// `std.unicode.utf8Decode` is deprecated and would re-derive the width
/// from a slice every caller has already measured.
fn decodeSeq(bytes: []const u8, i: usize, len: usize) ?u21 {
    const seq = bytes[i..][0..len];
    const cp: u21 = switch (len) {
        1 => @as(u21, seq[0]),
        2 => std.unicode.utf8Decode2(seq[0..2].*),
        3 => std.unicode.utf8Decode3(seq[0..3].*),
        4 => std.unicode.utf8Decode4(seq[0..4].*),
        else => unreachable,
    } catch return null;
    return cp;
}

/// Encode `cp` into `buf` and return the length, or 0 for a scalar no
/// UTF-8 form exists for. `copy` only reaches this with scalars
/// `decodeSeq` accepted, so 0 is a defensive no-op, not a leak.
fn encodeInto(buf: *[4]u8, cp: u21) usize {
    return std.unicode.utf8Encode(cp, buf) catch 0;
}

/// One-shot whole-buffer filter: `Sanitizer` with fresh state over the
/// whole of `src`, scanned into one buffer the caller owns. Nothing is
/// split, copied per line, or regrown. Tab and newline are structure,
/// so the result keeps the source's line shape even where a sequence
/// runs across a break. Use `Sanitizer` directly to filter a stream.
pub fn sanitize(allocator: std.mem.Allocator, src: []const u8) Error![]u8 {
    var s: Sanitizer = .{};
    return s.sanitize(allocator, src);
}

/// Block metadata shared by parse items and rendered lines.
const Meta = struct {
    kind: Kind = .paragraph,
    level: u8 = 0,
    indent: u8 = 0,
    ordered: bool = false,
    lang: []const u8 = "",
    /// Identifies the fence a code item came from, so two adjacent
    /// blocks stay two blocks (two highlighter calls, two info
    /// strings) instead of merging into one run of code rows.
    fence_id: u32 = 0,
};

/// One block-level construct before wrapping.
const Item = struct {
    meta: Meta = .{},
    /// Inline source for paragraph/heading/list items.
    text: []const u8 = "",
    /// Marker text for list items ("-", "1."), else "".
    marker: []const u8 = "",
    /// Verbatim text for `kind == .code`, else "".
    raw: []const u8 = "",
};

/// Markdown renderer. `render` interprets `src`, sanitises it, and lays
/// out styled rows into one arena owned by this struct: there is no
/// other allocation site in the module.
pub const Renderer = struct {
    arena: std.heap.ArenaAllocator,
    sanitizer: Sanitizer = .{},

    /// Create a renderer whose arena is backed by `gpa`. Nothing is
    /// allocated until the first `render`.
    pub fn init(gpa: std.mem.Allocator) Renderer {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    /// Free the arena and every slice it handed out; the renderer must
    /// not be used afterwards.
    pub fn deinit(self: *Renderer) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Render `src`. The document is filtered once into this renderer's
    /// arena and every slice below borrows that copy, never the
    /// caller's source. All result slices stay valid until the next
    /// `render` call or `deinit`.
    pub fn render(self: *Renderer, src: []const u8, opts: Options) Error!Block {
        _ = self.arena.reset(.retain_capacity);
        const arena = self.arena.allocator();
        self.sanitizer = .{}; // fresh state per document

        const items = try self.structure(arena, src, opts);
        var lines: std.ArrayList(Line) = .empty;
        var code_start: ?usize = null;
        var code_lang: []const u8 = "";
        var code_fence: u32 = 0;
        for (items) |item| {
            if (item.meta.kind != .code) {
                if (code_start) |start| {
                    try runHighlighter(arena, opts, code_lang, lines.items[start..]);
                    code_start = null;
                }
                try emit(arena, &lines, item, opts);
                continue;
            }
            if (code_start == null or item.meta.fence_id != code_fence) {
                // A fence of its own: flush the previous block first, so
                // adjacent blocks keep their own rows, info string and
                // highlighter call (even with the same language).
                if (code_start) |start|
                    try runHighlighter(arena, opts, code_lang, lines.items[start..]);
                code_start = lines.items.len;
                code_lang = item.meta.lang;
                code_fence = item.meta.fence_id;
            }
            try emit(arena, &lines, item, opts);
        }
        if (code_start) |start| try runHighlighter(arena, opts, code_lang, lines.items[start..]);
        return .{ .lines = try lines.toOwnedSlice(arena) };
    }

    /// Filter `src` into the arena as one sanitised document, then
    /// group its lines into block items: headings, fences, list items,
    /// paragraphs, blank separators. Every slice an `Item` borrows
    /// lives in that one arena copy, so nothing points at the caller's
    /// source; a line is copied again only where it really changes.
    fn structure(
        self: *Renderer,
        arena: std.mem.Allocator,
        src: []const u8,
        opts: Options,
    ) Error![]Item {
        const doc = try self.sanitizer.sanitize(arena, src);
        var raw_lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, doc, '\n');
        while (it.next()) |line| {
            try raw_lines.append(arena, try expandTabs(arena, line, opts.tab_width));
        }
        // A trailing newline terminates the last line; it does not open
        // an empty one (which would otherwise become a phantom code row
        // inside an unterminated fence).
        if (doc.len != 0 and doc[doc.len - 1] == '\n' and raw_lines.items.len != 0) {
            raw_lines.items.len -= 1;
        }

        var items: std.ArrayList(Item) = .empty;
        var i: usize = 0;
        var fence_id: u32 = 0;
        while (i < raw_lines.items.len) {
            const line = raw_lines.items[i];

            if (isBlank(line)) {
                // Collapse runs; a leading blank emits nothing.
                const prev_blank = items.items.len != 0 and
                    items.items[items.items.len - 1].meta.kind == .blank;
                if (items.items.len != 0 and !prev_blank) {
                    try items.append(arena, .{ .meta = .{ .kind = .blank } });
                }
                i += 1;
                continue;
            }

            if (parseFenceStart(line)) |fence| {
                i += 1;
                fence_id += 1; // every fence opens its own block identity
                while (i < raw_lines.items.len and
                    !fenceCloses(raw_lines.items[i], fence)) : (i += 1)
                {
                    try items.append(arena, .{
                        .meta = .{
                            .kind = .code,
                            .lang = fence.info,
                            .fence_id = fence_id,
                        },
                        .raw = raw_lines.items[i],
                    });
                }
                // Unterminated fence: input ends inside it, nothing else
                // is consumed (malformed input terminates, never swallows).
                if (i < raw_lines.items.len) i += 1; // closing fence
                continue;
            }

            if (parseHeading(line)) |head| {
                try items.append(arena, .{
                    .meta = .{ .kind = .heading, .level = head.level },
                    .text = head.text,
                });
                i += 1;
                continue;
            }

            if (parseListItem(line, opts.indent_width)) |mark| {
                const lead = countLeadingSpaces(line);
                var text = mark.rest;
                var j = i + 1;
                // Lazy continuation: deeper, non-structural lines join the
                // item and wrap with it.
                while (j < raw_lines.items.len) : (j += 1) {
                    const next = raw_lines.items[j];
                    if (isBlank(next)) break;
                    if (countLeadingSpaces(next) <= lead) break;
                    if (parseListItem(next, opts.indent_width) != null) break;
                    if (parseFenceStart(next) != null) break;
                    if (parseHeading(next) != null) break;
                    text = try std.mem.concat(arena, u8, &.{ text, " ", trimSpaces(next) });
                }
                try items.append(arena, .{
                    .meta = .{
                        .kind = .list_item,
                        .indent = mark.indent,
                        .ordered = mark.ordered,
                    },
                    .text = text,
                    .marker = mark.marker,
                });
                i = j;
                continue;
            }

            // Paragraph: join following plain lines with single spaces.
            var text: []const u8 = trimSpaces(line);
            var j = i + 1;
            while (j < raw_lines.items.len) : (j += 1) {
                const next = raw_lines.items[j];
                if (isBlank(next)) break;
                if (parseFenceStart(next) != null) break;
                if (parseHeading(next) != null) break;
                if (parseListItem(next, opts.indent_width) != null) break;
                text = try std.mem.concat(arena, u8, &.{ text, " ", trimSpaces(next) });
            }
            try items.append(arena, .{ .meta = .{ .kind = .paragraph }, .text = text });
            i = j;
        }

        // No leading (never emitted) or trailing blank rows.
        var n = items.items.len;
        while (n > 0 and items.items[n - 1].meta.kind == .blank) n -= 1;
        items.items.len = n;
        return items.toOwnedSlice(arena);
    }
};

/// Run the caller's highlighter over one code block's rendered lines.
fn runHighlighter(
    arena: std.mem.Allocator,
    opts: Options,
    lang: []const u8,
    lines: []Line,
) Error!void {
    const hook = opts.highlighter orelse return;
    if (lines.len == 0) return;
    try hook(arena, opts.highlighter_ctx, lang, lines);
}

/// Turn one block item into `Line`s, parsing inline markup and wrapping.
fn emit(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Line),
    item: Item,
    opts: Options,
) Error!void {
    if (item.meta.kind == .blank) {
        try out.append(arena, .{ .spans = try arena.alloc(Span, 0), .kind = .blank });
        return;
    }

    if (item.meta.kind == .code) {
        var spans: std.ArrayList(Span) = .empty;
        if (item.raw.len != 0) try appendSpan(arena, &spans, item.raw, opts.code, null);
        try wrapCode(arena, out, spans.items, item.meta, opts);
        return;
    }

    const base: Style = switch (item.meta.kind) {
        .heading => opts.heading.merge(.{ .attrs = .{ .bold = true } }),
        else => .{},
    };

    var prefix: std.ArrayList(Span) = .empty;
    if (item.marker.len != 0) {
        try appendSpan(arena, &prefix, item.marker, opts.marker, null);
        try appendSpan(arena, &prefix, " ", opts.marker, null);
    }

    var spans: std.ArrayList(Span) = .empty;
    try parseInline(arena, item.text, base, null, &spans, 0, opts);
    try wrapWords(arena, out, spans.items, prefix.items, item.meta, opts);
}

/// Parse inline markdown (code, bold, italic, strikethrough, links) into
/// spans, recursing into emphasis and link bodies. Unmatched delimiters
/// stay literal.
fn parseInline(
    arena: std.mem.Allocator,
    text: []const u8,
    base: Style,
    url: ?[]const u8,
    out: *std.ArrayList(Span),
    depth: u8,
    opts: Options,
) Error!void {
    if (depth > 8) { // pathological nesting: stop, keep the text
        try appendSpan(arena, out, text, base, url);
        return;
    }

    var i: usize = 0;
    var run: usize = 0;
    while (i < text.len) {
        switch (text[i]) {
            '`' => {
                if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |end| {
                    try appendSpan(arena, out, text[run..i], base, url);
                    try appendSpan(arena, out, text[i + 1 .. end], opts.code.merge(base), url);
                    i = end + 1;
                    run = i;
                } else i += 1;
            },
            '*' => {
                if (boldEnd(text, i)) |end| {
                    var style = base;
                    style.attrs.bold = true;
                    try appendSpan(arena, out, text[run..i], base, url);
                    try parseInline(arena, text[i + 2 .. end], style, url, out, depth + 1, opts);
                    i = end + 2;
                    run = i;
                } else if (italicEnd(text, i)) |end| {
                    var style = base;
                    style.attrs.italic = true;
                    try appendSpan(arena, out, text[run..i], base, url);
                    try parseInline(arena, text[i + 1 .. end], style, url, out, depth + 1, opts);
                    i = end + 1;
                    run = i;
                } else i += 1;
            },
            '~' => {
                if (strikeEnd(text, i)) |end| {
                    var style = base;
                    style.attrs.strikethrough = true;
                    try appendSpan(arena, out, text[run..i], base, url);
                    try parseInline(arena, text[i + 2 .. end], style, url, out, depth + 1, opts);
                    i = end + 2;
                    run = i;
                } else i += 1;
            },
            '[' => {
                if (linkEnd(text, i)) |l| {
                    try appendSpan(arena, out, text[run..i], base, url);
                    try parseInline(
                        arena,
                        text[i + 1 .. l.text_end],
                        opts.link.merge(base),
                        text[l.url_start..l.url_end],
                        out,
                        depth + 1,
                        opts,
                    );
                    i = l.url_end + 1;
                    run = i;
                } else i += 1;
            },
            else => i += 1,
        }
    }
    try appendSpan(arena, out, text[run..], base, url);
}

/// Closing byte offset of a valid `**...**` run opened at `i`.
fn boldEnd(text: []const u8, i: usize) ?usize {
    if (i + 1 >= text.len or text[i + 1] != '*') return null;
    const end = std.mem.indexOfPos(u8, text, i + 2, "**") orelse return null;
    if (end == i + 2) return null; // empty run: keep the asterisks
    return end;
}

/// Closing byte offset of a valid `*...*` run opened at `i`.
fn italicEnd(text: []const u8, i: usize) ?usize {
    if (i + 1 < text.len and text[i + 1] == '*') return null; // bold opener
    const end = std.mem.indexOfScalarPos(u8, text, i + 1, '*') orelse return null;
    if (end == i + 1) return null;
    return end;
}

/// Closing byte offset of a valid `~~...~~` run opened at `i`.
fn strikeEnd(text: []const u8, i: usize) ?usize {
    if (i + 1 >= text.len or text[i + 1] != '~') return null;
    const end = std.mem.indexOfPos(u8, text, i + 2, "~~") orelse return null;
    if (end == i + 2) return null;
    return end;
}

const LinkOffsets = struct { text_end: usize, url_start: usize, url_end: usize };

/// Byte offsets of a `[text](url)` construct opened at `i`.
fn linkEnd(text: []const u8, i: usize) ?LinkOffsets {
    const close = std.mem.indexOfScalarPos(u8, text, i + 1, ']') orelse return null;
    if (close + 1 >= text.len or text[close + 1] != '(') return null;
    const end = std.mem.indexOfScalarPos(u8, text, close + 2, ')') orelse return null;
    if (end == close + 2) return null; // empty target: keep the brackets
    return .{ .text_end = close, .url_start = close + 2, .url_end = end };
}

const Word = struct {
    text: []const u8,
    style: Style,
    url: ?[]const u8,
    width: usize,
    /// A space separated this word from the previous one.
    sep: bool,
    /// The separating space keeps the style of the run it came from, so
    /// link styling never spreads onto neighbouring text.
    sep_style: Style = .{},
    sep_url: ?[]const u8 = null,
};

/// Input to `pushWord`: one unbroken run plus its separator metadata.
const WordSpec = struct {
    text: []const u8,
    style: Style,
    url: ?[]const u8,
    sep: bool,
    sep_style: Style,
    sep_url: ?[]const u8,
    wrap_width: usize,
};

/// Wrap styled runs at word boundaries through the width seam. Words
/// wider than the budget split at grapheme-cluster boundaries only, so
/// a hard tab or a CJK double-width grapheme never splits.
fn wrapWords(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Line),
    spans: []const Span,
    prefix: []const Span,
    meta: Meta,
    opts: Options,
) Error!void {
    var words: std.ArrayList(Word) = .empty;
    var pending_sep = false;
    var sep_style: Style = .{};
    var sep_url: ?[]const u8 = null;
    var at_start = true;
    for (spans) |span| {
        var idx: usize = 0;
        while (idx < span.text.len) {
            if (span.text[idx] == ' ') { // ASCII space never splits a cluster
                pending_sep = true;
                sep_style = span.style;
                sep_url = span.url;
                idx += 1;
                continue;
            }
            const start = idx;
            while (idx < span.text.len and span.text[idx] != ' ') idx += 1;
            try pushWord(arena, &words, .{
                .text = span.text[start..idx],
                .style = span.style,
                .url = span.url,
                .sep = pending_sep and !at_start,
                .sep_style = sep_style,
                .sep_url = sep_url,
                .wrap_width = opts.width,
            });
            pending_sep = false;
            at_start = false;
        }
    }

    var line_spans: std.ArrayList(Span) = .empty;
    var col: usize = 0;
    for (prefix) |sp| {
        try appendSpan(arena, &line_spans, sp.text, sp.style, sp.url);
        col += Width.strWidth(sp.text);
    }

    for (words.items) |word| {
        const sep_w: usize = if (word.sep and col > 0) 1 else 0;
        if (opts.width > 0 and col > 0 and col + sep_w + word.width > opts.width) {
            try flush(arena, out, &line_spans, meta);
            col = 0;
        }
        if (word.sep and col > 0) {
            try appendSpan(arena, &line_spans, " ", word.sep_style, word.sep_url);
            col += 1;
        }
        try appendSpan(arena, &line_spans, word.text, word.style, word.url);
        col += word.width;
    }
    try flush(arena, out, &line_spans, meta);
}

/// Wrap code verbatim: every byte (including runs of spaces) is
/// preserved and history is broken only at cluster boundaries.
fn wrapCode(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Line),
    spans: []const Span,
    meta: Meta,
    opts: Options,
) Error!void {
    var line_spans: std.ArrayList(Span) = .empty;
    var col: usize = 0;
    for (spans) |span| {
        var off: usize = 0;
        while (off < span.text.len) {
            const glen = Width.firstGraphemeLen(span.text[off..]);
            if (glen == 0) break; // defensive: valid UTF-8 always progresses
            const gc = span.text[off..][0..glen];
            const gw = Width.graphemeWidth(gc);
            const gwu: usize = if (gw > 0) @intCast(gw) else 0;
            if (opts.width > 0 and col > 0 and col + gwu > opts.width) {
                try flush(arena, out, &line_spans, meta);
                col = 0;
            }
            try appendSpan(arena, &line_spans, gc, span.style, span.url);
            col += gwu;
            off += glen;
        }
    }
    try flush(arena, out, &line_spans, meta);
}

/// Split `spec.text` into pieces that fit `spec.wrap_width` (cluster-safe),
/// appending them to `words`. Separator metadata rides on the first piece
/// so a wrapped word never re-emits a separator mid-run.
fn pushWord(arena: std.mem.Allocator, words: *std.ArrayList(Word), spec: WordSpec) Error!void {
    const text = spec.text;
    const w = Width.strWidth(text);
    if (spec.wrap_width == 0 or w <= spec.wrap_width) {
        try words.append(arena, .{
            .text = text,
            .style = spec.style,
            .url = spec.url,
            .width = w,
            .sep = spec.sep,
            .sep_style = spec.sep_style,
            .sep_url = spec.sep_url,
        });
        return;
    }

    var off: usize = 0;
    var piece: usize = 0;
    var col: usize = 0;
    var first = true;
    while (off < text.len) {
        const glen = Width.firstGraphemeLen(text[off..]);
        if (glen == 0) break;
        const gc = text[off..][0..glen];
        const gw = Width.graphemeWidth(gc);
        const gwu: usize = if (gw > 0) @intCast(gw) else 0;
        if (col > 0 and col + gwu > spec.wrap_width) {
            try words.append(arena, .{
                .text = text[piece..off],
                .style = spec.style,
                .url = spec.url,
                .width = col,
                .sep = first and spec.sep,
                .sep_style = spec.sep_style,
                .sep_url = spec.sep_url,
            });
            first = false;
            piece = off;
            col = 0;
        }
        col += gwu;
        off += glen;
    }
    if (piece < text.len) {
        try words.append(arena, .{
            .text = text[piece..],
            .style = spec.style,
            .url = spec.url,
            .width = col,
            .sep = first and spec.sep,
            .sep_style = spec.sep_style,
            .sep_url = spec.sep_url,
        });
    }
}

/// Emit the accumulated spans as one line and start the next.
fn flush(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Line),
    line_spans: *std.ArrayList(Span),
    meta: Meta,
) Error!void {
    try out.append(arena, .{
        .spans = try line_spans.toOwnedSlice(arena),
        .kind = meta.kind,
        .level = meta.level,
        .indent = meta.indent,
        .ordered = meta.ordered,
        .lang = meta.lang,
    });
    line_spans.* = .empty;
}

/// Append a span, folding it into the previous one when the style
/// matches and the text is contiguous in memory (a free merge: the
/// combined slice is still borrowed, never copied).
fn appendSpan(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Span),
    text: []const u8,
    style: Style,
    url: ?[]const u8,
) Error!void {
    if (text.len == 0) return;
    if (out.items.len != 0) {
        const last = out.items[out.items.len - 1];
        if (last.style.eql(style) and urlEql(last.url, url) and
            last.text.ptr + last.text.len == text.ptr)
        {
            out.items[out.items.len - 1].text = last.text.ptr[0 .. last.text.len + text.len];
            return;
        }
    }
    try out.append(arena, .{ .text = text, .style = style, .url = url });
}

fn urlEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |sa| {
        if (b) |sb| return std.mem.eql(u8, sa, sb);
        return false;
    }
    return b == null;
}

const Fence = struct { ch: u8, len: usize, info: []const u8 };

/// Opening fence (` ``` ` or `~~~`, at least three) with its info string.
fn parseFenceStart(line: []const u8) ?Fence {
    const s = std.mem.trimStart(u8, line, " ");
    if (s.len < 3) return null;
    const ch = s[0];
    if (ch != '`' and ch != '~') return null;
    var n: usize = 0;
    while (n < s.len and s[n] == ch) n += 1;
    if (n < 3) return null;
    // A backtick info string may not contain a backtick (CommonMark).
    if (ch == '`' and std.mem.indexOfScalar(u8, s[n..], '`') != null) return null;
    return .{ .ch = ch, .len = n, .info = trimSpaces(s[n..]) };
}

/// Whether `line` closes the fence `f`: same character, at least as
/// long, nothing but spaces after.
fn fenceCloses(line: []const u8, f: Fence) bool {
    const s = std.mem.trimStart(u8, line, " ");
    var n: usize = 0;
    while (n < s.len and s[n] == f.ch) n += 1;
    if (n < f.len) return false;
    return trimSpaces(s[n..]).len == 0;
}

const Heading = struct { level: u8, text: []const u8 };

/// ATX heading `#`..`######` (space or end of line required after the
/// hashes; a trailing hash run preceded by a space is decoration).
fn parseHeading(line: []const u8) ?Heading {
    const s = std.mem.trimStart(u8, line, " ");
    var n: usize = 0;
    while (n < s.len and s[n] == '#') n += 1;
    if (n == 0 or n > 6) return null;
    if (n < s.len and s[n] != ' ') return null;

    var text = trimSpaces(s[n..]);
    if (text.len != 0 and text[text.len - 1] == '#') {
        var end = text.len;
        while (end > 0 and text[end - 1] == '#') end -= 1;
        if (end == 0) {
            text = "";
        } else if (text[end - 1] == ' ') {
            text = std.mem.trimEnd(u8, text[0..end], " ");
        }
    }
    return .{ .level = @intCast(n), .text = text };
}

const Marker = struct {
    indent: u8,
    ordered: bool,
    marker: []const u8,
    rest: []const u8,
};

/// List item marker (`-`, `*`, `+`, `1.`, `1)`) with nesting depth by
/// leading spaces. A marker must be followed by a space or the end of
/// the line, so `*text*` stays emphasis.
fn parseListItem(line: []const u8, indent_width: usize) ?Marker {
    const lead = countLeadingSpaces(line);
    var i = lead;
    if (i >= line.len) return null;

    const marker_start = i;
    var ordered = false;
    const c = line[i];
    if (c == '-' or c == '*' or c == '+') {
        i += 1;
    } else if (std.ascii.isDigit(c)) {
        ordered = true;
        while (i < line.len and std.ascii.isDigit(line[i]) and i - marker_start < 9) i += 1;
        if (i >= line.len or (line[i] != '.' and line[i] != ')')) return null;
        i += 1;
    } else return null;
    if (i < line.len and line[i] != ' ') return null;

    const depth: usize = if (indent_width == 0) 0 else lead / indent_width;
    return .{
        .indent = @intCast(@min(depth, 255)),
        .ordered = ordered,
        .marker = line[marker_start..i],
        .rest = trimSpaces(line[i..]),
    };
}

fn countLeadingSpaces(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') n += 1;
    return n;
}

fn trimSpaces(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " ");
}

fn isBlank(line: []const u8) bool {
    return trimSpaces(line).len == 0;
}

/// Expand hard tabs to spaces at `tab_width` stops, measuring each
/// grapheme through the width seam. Lines without tabs are returned
/// borrowed.
fn expandTabs(arena: std.mem.Allocator, line: []const u8, tab_width: usize) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, line, '\t') == null) return line;

    var out = try std.ArrayList(u8).initCapacity(arena, line.len +| 8);
    var col: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '\t') {
            const spaces = if (tab_width == 0) 1 else tab_width - (col % tab_width);
            try out.appendNTimes(arena, ' ', spaces);
            col += spaces;
            i += 1;
            continue;
        }
        const glen = Width.firstGraphemeLen(line[i..]);
        if (glen == 0) break;
        const gc = line[i..][0..glen];
        try out.appendSlice(arena, gc);
        const w = Width.graphemeWidth(gc);
        if (w > 0) col += @intCast(w);
        i += glen;
    }
    return out.toOwnedSlice(arena);
}

const test_alloc = std.testing.allocator;

/// Concatenate every span text in the block (line breaks dropped).
fn flatten(alloc: std.mem.Allocator, block: Block) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (block.lines) |line| {
        for (line.spans) |span| try out.appendSlice(alloc, span.text);
    }
    return out.toOwnedSlice(alloc);
}

/// Concatenate one line's span texts.
fn lineText(alloc: std.mem.Allocator, line: Line) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (line.spans) |span| try out.appendSlice(alloc, span.text);
    return out.toOwnedSlice(alloc);
}

fn expectLineText(alloc: std.mem.Allocator, line: Line, want: []const u8) !void {
    const got = try lineText(alloc, line);
    defer alloc.free(got);
    try std.testing.expectEqualStrings(want, got);
}

/// True when `s` holds any control codepoint (C0, DEL, C1) or is not
/// valid UTF-8 — the property every `Span.text` must satisfy.
fn hasForbiddenCodepoint(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        const len: usize = std.unicode.utf8ByteSequenceLength(s[i]) catch return true;
        if (len > s.len - i) return true;
        const cp = decodeSeq(s, i, len) orelse return true;
        i += len;
        if (isForbidden(cp)) return true;
    }
    return false;
}

test "sanitize: controls and escape families are stripped" {
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "\x1b[31mred\x1b[0m", .want = "red" },
        .{ .in = "\x1b]0;title\x07visible", .want = "visible" },
        .{ .in = "a\x1bPdcs\x1b\\b", .want = "ab" },
        .{ .in = "a\x1b_pc\x1b\\b", .want = "ab" },
        .{ .in = "a\x1bXsos\x1b\\b", .want = "ab" },
        .{ .in = "a\x1b^pm\x1b\\b", .want = "ab" },
        .{ .in = "a\x07\x08\x0b\x0c\r\x7fb", .want = "ab" },
        .{ .in = "a\u{009B}31mb", .want = "ab" }, // 8-bit CSI
        .{ .in = "a\u{009D}0;t\u{0007}b", .want = "ab" }, // 8-bit OSC
        // Tab, newline and Û (whose C3 9B bytes contain 0x9B as a
        // continuation) all survive: filtering is per codepoint.
        .{ .in = "keep\tthis\nand\u{00DB}this", .want = "keep\tthis\nand\u{00DB}this" },
    };
    for (cases) |case| {
        const got = try sanitize(test_alloc, case.in);
        defer test_alloc.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
}

test "sanitize: an unterminated sequence fails closed" {
    const out = try sanitize(test_alloc, "a\x1b]0;title never closes\nb");
    defer test_alloc.free(out);
    try std.testing.expectEqualStrings("a\n", out);
}

test "sanitize: state carries across chunks" {
    var s: Sanitizer = .{};
    const first = try s.sanitize(test_alloc, "before \x1b[3");
    defer test_alloc.free(first);
    try std.testing.expectEqualStrings("before ", first);

    const second = try s.sanitize(test_alloc, "1m after");
    defer test_alloc.free(second);
    try std.testing.expectEqualStrings(" after", second);
}

test "sanitize: accept is a per-codepoint, allocation-free verdict" {
    var s: Sanitizer = .{};
    try std.testing.expect(s.accept('a'));
    try std.testing.expect(!s.accept(0x1B)); // ESC
    try std.testing.expect(!s.accept('[')); // CSI introducer
    try std.testing.expect(!s.accept('3'));
    try std.testing.expect(!s.accept('1'));
    try std.testing.expect(!s.accept('m')); // final byte closes the sequence
    try std.testing.expect(s.accept('b')); // ground again

    // Tab and newline survive; every other control does not.
    try std.testing.expect(s.accept('\t'));
    try std.testing.expect(s.accept('\n'));
    try std.testing.expect(!s.accept(0x07));
    try std.testing.expect(!s.accept(0x7F));

    // The 8-bit C1 form behaves like its 7-bit spelling.
    try std.testing.expect(!s.accept(0x009B));
    try std.testing.expect(!s.accept('3'));
    try std.testing.expect(!s.accept('m'));
    try std.testing.expect(s.accept('c'));

    // Non-ASCII scalars pass, including Û (whose C3 9B bytes contain the
    // 8-bit CSI byte as a continuation).
    try std.testing.expect(s.accept(0x00DB));
}

test "sanitize: acceptCluster keeps clusters whole and consumes escapes" {
    var s: Sanitizer = .{};
    try std.testing.expect(s.acceptCluster("e\u{301}")); // base plus mark
    try std.testing.expect(s.acceptCluster("👨‍🌾")); // ZWJ family

    // A dropped cluster still advances the machine, so a sequence that
    // spans cluster boundaries (ESC, '[', params, final) is consumed as
    // one — the orphan "[31m" never becomes text.
    try std.testing.expect(!s.acceptCluster("\x1b["));
    try std.testing.expect(!s.acceptCluster("3"));
    try std.testing.expect(!s.acceptCluster("m")); // final byte
    try std.testing.expect(s.acceptCluster("z")); // ground again

    // The 8-bit C1 introducer arms the same machine.
    try std.testing.expect(!s.acceptCluster("\u{009B}"));
    try std.testing.expect(!s.acceptCluster("2"));
    try std.testing.expect(!s.acceptCluster("J"));
    try std.testing.expect(s.acceptCluster("y"));

    // Invalid UTF-8 is dropped and arms nothing, exactly as the copying
    // form drops it.
    try std.testing.expect(!s.acceptCluster("\xff"));
    try std.testing.expect(s.acceptCluster("x"));
}

test "sanitize: a fragmented string escape keeps eating its payload" {
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        // An ESC inside a string terminates it only when `\` follows.
        // Tab is structure and passes; everything between the ESC and
        // the real terminator stays consumed.
        .{ .in = "\x1b]0;title\x1b\tafter\x07rest", .want = "\trest" },
        .{ .in = "\x1b]0;title\x1b[31mafter\x07rest", .want = "rest" },
        .{ .in = "a\x1bPdcs\x1bXmore\x1b\\ok", .want = "aok" },
        // BEL ends OSC only. In DCS it is payload, and the block keeps
        // consuming what follows.
        .{ .in = "\x1b]0;title\x07visible", .want = "visible" },
        .{ .in = "a\x1bPdcs\x07b", .want = "a" },
        // ST in either spelling ends every string family.
        .{ .in = "a\x1bPdcs\x1b\\b", .want = "ab" },
        .{ .in = "a\x1bPdcs\u{009C}b", .want = "ab" },
        .{ .in = "a\x1b]0;title\u{009C}b", .want = "ab" },
    };
    for (cases) |case| {
        const got = try sanitize(test_alloc, case.in);
        defer test_alloc.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
}

test "sanitize: a newline steers the machine without ending a sequence" {
    // A line break is a chunk boundary, not a terminator: the CSI eats
    // its parameters on the next line.
    const csi = try sanitize(test_alloc, "before \x1b[3\n1m after");
    defer test_alloc.free(csi);
    try std.testing.expectEqualStrings("before \n after", csi);

    // A bare ESC at end of line is a broken escape, so the break
    // grounds it and the next line is text again.
    const esc = try sanitize(test_alloc, "a\x1b\nb");
    defer test_alloc.free(esc);
    try std.testing.expectEqualStrings("a\nb", esc);

    // An unterminated string still swallows the lines it covers,
    // newlines aside.
    const osc = try sanitize(test_alloc, "a \x1b]0;title\nhidden\x07 tail\n");
    defer test_alloc.free(osc);
    try std.testing.expectEqualStrings("a \n tail\n", osc);
}

test "sanitize: accept verdicts hold inside a fragmented string" {
    var s: Sanitizer = .{};
    try std.testing.expect(!s.accept(0x1B));
    try std.testing.expect(!s.accept(']')); // OSC opens
    for ("0;title") |c| try std.testing.expect(!s.accept(c));
    try std.testing.expect(!s.accept(0x1B)); // ESC inside the string
    try std.testing.expect(s.accept('\t')); // structure still passes
    for ("after") |c| try std.testing.expect(!s.accept(c)); // still inside
    try std.testing.expect(!s.accept(0x07)); // BEL ends OSC
    try std.testing.expect(s.accept('z'));

    // The cluster form reaches the same verdicts.
    var d: Sanitizer = .{};
    try std.testing.expect(!d.acceptCluster("\x1bP")); // DCS opens
    try std.testing.expect(!d.acceptCluster("\x1b\tpayload"));
    try std.testing.expect(!d.acceptCluster("\x07")); // payload, not an end
    try std.testing.expect(!d.acceptCluster("q"));
    try std.testing.expect(!d.acceptCluster("\x1b\\")); // ST ends DCS
    try std.testing.expect(d.acceptCluster("q"));
}

test "markdown: injections never reach a span (heading, list, fence, link)" {
    var r = Renderer.init(test_alloc);
    defer r.deinit();

    const src = "# head \x1b[31mred\x1b[0m\n" ++
        "- item \x1b]0;title\x07tail\n" ++
        "```\n" ++
        "code \x1b[2Jclear\n" ++
        "```\n" ++
        "[link\x1b[1m text](https://e.example)\n" ++
        "inline `\x1b[5mblink\x1b[0m` end\n";
    const block = try r.render(src, .{});

    for (block.lines) |line| {
        for (line.spans) |span| {
            try std.testing.expect(!hasForbiddenCodepoint(span.text));
        }
    }

    const flat = try flatten(test_alloc, block);
    defer test_alloc.free(flat);
    try std.testing.expect(std.mem.indexOf(u8, flat, "head red") != null);
    try std.testing.expect(std.mem.indexOf(u8, flat, "item tail") != null);
    try std.testing.expect(std.mem.indexOf(u8, flat, "code clear") != null);
    try std.testing.expect(std.mem.indexOf(u8, flat, "link text") != null);
    try std.testing.expect(std.mem.indexOf(u8, flat, "inline blink end") != null);
    // Escape bodies are consumed, not left as literal text.
    try std.testing.expect(std.mem.indexOf(u8, flat, "title") == null);
    try std.testing.expect(std.mem.indexOf(u8, flat, "31m") == null);
    // The link target is metadata only.
    try std.testing.expect(std.mem.indexOf(u8, flat, "e.example") == null);
}

test "markdown: CSI split across a fence line break stays stripped" {
    var r = Renderer.init(test_alloc);
    defer r.deinit();

    const block = try r.render("```\nbefore \x1b[3\n1m after\n```\n", .{});
    try std.testing.expectEqual(@as(usize, 2), block.lines.len);
    try std.testing.expectEqual(Kind.code, block.lines[0].kind);
    try std.testing.expectEqual(Kind.code, block.lines[1].kind);
    try expectLineText(test_alloc, block.lines[0], "before ");
    try expectLineText(test_alloc, block.lines[1], " after");

    const flat = try flatten(test_alloc, block);
    defer test_alloc.free(flat);
    try std.testing.expectEqualStrings("before  after", flat);
    try std.testing.expect(std.mem.indexOf(u8, flat, "[3") == null);
    try std.testing.expect(std.mem.indexOf(u8, flat, "1m") == null);
}

test "markdown: empty document yields zero lines" {
    var r = Renderer.init(test_alloc);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try r.render("", .{})).lines.len);
    try std.testing.expectEqual(@as(usize, 0), (try r.render("\n\n", .{})).lines.len);
}

test "markdown: unterminated fence terminates at end of input" {
    var r = Renderer.init(test_alloc);
    defer r.deinit();

    const block = try r.render("```\nunclosed\nmore\n", .{});
    try std.testing.expectEqual(@as(usize, 2), block.lines.len);
    try std.testing.expectEqual(Kind.code, block.lines[0].kind);
    try expectLineText(test_alloc, block.lines[0], "unclosed");
    try expectLineText(test_alloc, block.lines[1], "more");
}

test "markdown: bold, italic, strikethrough and code carry styles" {
    var r = Renderer.init(test_alloc);
    defer r.deinit();

    const opts: Options = .{ .code = .{ .fg = .{ .ansi = .cyan } } };
    const block = try r.render("a **bold** *italic* ~~gone~~ `code`\n", opts);
    try std.testing.expectEqual(@as(usize, 1), block.lines.len);
    try expectLineText(test_alloc, block.lines[0], "a bold italic gone code");

    var seen: u8 = 0;
    for (block.lines[0].spans) |span| {
        if (std.mem.eql(u8, span.text, "bold")) {
            seen += 1;
            try std.testing.expect(span.style.attrs.bold);
            try std.testing.expect(!span.style.attrs.italic);
        } else if (std.mem.eql(u8, span.text, "italic")) {
            seen += 1;
            try std.testing.expect(span.style.attrs.italic);
            try std.testing.expect(!span.style.attrs.bold);
        } else if (std.mem.eql(u8, span.text, "gone")) {
            seen += 1;
            try std.testing.expect(span.style.attrs.strikethrough);
        } else if (std.mem.eql(u8, span.text, "code")) {
            seen += 1;
            try std.testing.expectEqual(Color{ .ansi = .cyan }, span.style.fg.?);
        }
    }
    try std.testing.expectEqual(@as(u8, 4), seen);
}

test "markdown: wrapping never splits a grapheme cluster" {
    var r = Renderer.init(test_alloc);
    defer r.deinit();

    // CJK: every codepoint is two cells wide, so a 4-cell budget holds
    // exactly two of them per row.
    const cjk = try r.render("汉字汉字汉字\n", .{ .width = 4 });
    try std.testing.expectEqual(@as(usize, 3), cjk.lines.len);
    for (cjk.lines) |line| {
        const t = try lineText(test_alloc, line);
        defer test_alloc.free(t);
        try std.testing.expectEqual(@as(usize, 4), Width.strWidth(t));
        try std.testing.expect(std.unicode.utf8ValidateSlice(t));
    }

    // A ZWJ family is one cluster 2 cells wide and must stay whole.
    const emoji = try r.render("👨‍🌾ab\n", .{ .width = 2 });
    try std.testing.expectEqual(@as(usize, 2), emoji.lines.len);
    try expectLineText(test_alloc, emoji.lines[0], "👨‍🌾");
    try expectLineText(test_alloc, emoji.lines[1], "ab");
}

test "markdown: word wrap breaks at spaces and keeps the budget" {
    var r = Renderer.init(test_alloc);
    defer r.deinit();

    const block = try r.render("The quick brown fox\n", .{ .width = 10 });
    try std.testing.expectEqual(@as(usize, 2), block.lines.len);
    try expectLineText(test_alloc, block.lines[0], "The quick");
    try expectLineText(test_alloc, block.lines[1], "brown fox");
    for (block.lines) |line| {
        const t = try lineText(test_alloc, line);
        defer test_alloc.free(t);
        try std.testing.expect(Width.strWidth(t) <= 10);
    }
}

test "markdown: ATX headings carry level, text and bold" {
    var r = Renderer.init(test_alloc);
    defer r.deinit();

    const block = try r.render("## Two ##\n###### six\n#nospace\n", .{});
    try std.testing.expectEqual(@as(usize, 3), block.lines.len);
    try std.testing.expectEqual(Kind.heading, block.lines[0].kind);
    try std.testing.expectEqual(@as(u8, 2), block.lines[0].level);
    try expectLineText(test_alloc, block.lines[0], "Two");
    try std.testing.expect(block.lines[0].spans[0].style.attrs.bold);
    try std.testing.expectEqual(@as(u8, 6), block.lines[1].level);
    try expectLineText(test_alloc, block.lines[1], "six");
    // Not a heading: no space after the hash.
    try std.testing.expectEqual(Kind.paragraph, block.lines[2].kind);
    try expectLineText(test_alloc, block.lines[2], "#nospace");
}

test "markdown: lists nest by indentation and keep markers" {
    var r = Renderer.init(test_alloc);
    defer r.deinit();

    const block = try r.render("- one\n  - nested\n1. first\n  2) second\n", .{});
    try std.testing.expectEqual(@as(usize, 4), block.lines.len);
    try std.testing.expectEqual(Kind.list_item, block.lines[0].kind);
    try std.testing.expectEqual(@as(u8, 0), block.lines[0].indent);
    try std.testing.expect(!block.lines[0].ordered);
    try expectLineText(test_alloc, block.lines[0], "- one");
    try std.testing.expectEqual(@as(u8, 1), block.lines[1].indent);
    try expectLineText(test_alloc, block.lines[1], "- nested");
    try std.testing.expect(block.lines[2].ordered);
    try expectLineText(test_alloc, block.lines[2], "1. first");
    try std.testing.expectEqual(@as(u8, 1), block.lines[3].indent);
    try std.testing.expect(block.lines[3].ordered);
    try expectLineText(test_alloc, block.lines[3], "2) second");
}

test "markdown: a lazy continuation joins its list item" {
    var r = Renderer.init(test_alloc);
    defer r.deinit();

    const block = try r.render("- first part\n  second part\n", .{});
    try std.testing.expectEqual(@as(usize, 1), block.lines.len);
    try expectLineText(test_alloc, block.lines[0], "- first part second part");
}

test "markdown: a hard tab is never a split point" {
    var r = Renderer.init(test_alloc);
    defer r.deinit();

    // Prose collapses whitespace like markdown: the tab is a word
    // separator, never a break inside a word.
    const prose = try r.render("a\tb\n", .{ .width = 8 });
    try expectLineText(test_alloc, prose.lines[0], "a b");

    // Code keeps its indentation: the tab becomes spaces up to the stop.
    const code = try r.render("```\n\tx\n```\n", .{ .tab_width = 4 });
    try expectLineText(test_alloc, code.lines[0], "    x");
}

test "markdown: paragraphs join soft breaks, blanks collapse" {
    var r = Renderer.init(test_alloc);
    defer r.deinit();

    const block = try r.render("one\ntwo\n\n\n# h\n\nthree\n\n", .{});
    try std.testing.expectEqual(@as(usize, 5), block.lines.len);
    try std.testing.expectEqual(Kind.paragraph, block.lines[0].kind);
    try expectLineText(test_alloc, block.lines[0], "one two");
    try std.testing.expectEqual(Kind.blank, block.lines[1].kind);
    try std.testing.expectEqual(@as(usize, 0), block.lines[1].spans.len);
    try std.testing.expectEqual(Kind.heading, block.lines[2].kind);
    try std.testing.expectEqual(Kind.blank, block.lines[3].kind);
    try expectLineText(test_alloc, block.lines[4], "three");
}

test "markdown: highlighter hook receives the fence info string" {
    const Hook = struct {
        const Self = @This();

        langs: usize = 0,
        lang: []const u8 = "",

        fn run(
            arena: std.mem.Allocator,
            ctx: ?*anyopaque,
            lang: []const u8,
            lines: []Line,
        ) Error!void {
            _ = arena;
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.langs += 1;
            self.lang = lang;
            for (lines) |*line| {
                for (line.spans) |*span| span.style = .{ .fg = .{ .ansi = .green } };
            }
        }
    };

    var r = Renderer.init(test_alloc);
    defer r.deinit();

    var hook: Hook = .{};
    const block = try r.render("```zig\nconst x = 1;\n```\n", .{
        .highlighter = Hook.run,
        .highlighter_ctx = &hook,
    });
    try std.testing.expectEqual(@as(usize, 1), hook.langs);
    try std.testing.expectEqualStrings("zig", hook.lang);
    try std.testing.expectEqual(@as(usize, 1), block.lines.len);
    try expectLineText(test_alloc, block.lines[0], "const x = 1;");
    try std.testing.expectEqual(Color{ .ansi = .green }, block.lines[0].spans[0].style.fg.?);
}

test "markdown: adjacent fences stay two blocks" {
    const Hook = struct {
        const Self = @This();

        calls: usize = 0,
        rows: usize = 0,
        langs: [4][]const u8 = .{ "", "", "", "" },

        fn run(
            arena: std.mem.Allocator,
            ctx: ?*anyopaque,
            lang: []const u8,
            lines: []Line,
        ) Error!void {
            _ = arena;
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            self.rows += lines.len;
            if (self.calls <= self.langs.len) self.langs[self.calls - 1] = lang;
        }
    };

    var r = Renderer.init(test_alloc);
    defer r.deinit();

    var hook: Hook = .{};
    const opts: Options = .{
        .highlighter = Hook.run,
        .highlighter_ctx = &hook,
    };
    const block = try r.render("```a\nx\n```\n```b\ny\n```\n", opts);

    // Two fences keep two blocks: two calls with their own info string,
    // one row each and no merged (or invented blank) row between.
    try std.testing.expectEqual(@as(usize, 2), hook.calls);
    try std.testing.expectEqual(@as(usize, 2), hook.rows);
    try std.testing.expectEqualStrings("a", hook.langs[0]);
    try std.testing.expectEqualStrings("b", hook.langs[1]);
    try std.testing.expectEqual(@as(usize, 2), block.lines.len);
    try std.testing.expectEqual(Kind.code, block.lines[0].kind);
    try std.testing.expectEqual(Kind.code, block.lines[1].kind);
    try std.testing.expectEqualStrings("a", block.lines[0].lang);
    try std.testing.expectEqualStrings("b", block.lines[1].lang);
    try expectLineText(test_alloc, block.lines[0], "x");
    try expectLineText(test_alloc, block.lines[1], "y");

    // The same language twice is still two blocks.
    hook = .{};
    const same = try r.render("```zig\nx\n```\n```zig\ny\n```\n", opts);
    try std.testing.expectEqual(@as(usize, 2), hook.calls);
    try std.testing.expectEqual(@as(usize, 2), same.lines.len);
    try expectLineText(test_alloc, same.lines[0], "x");
    try expectLineText(test_alloc, same.lines[1], "y");
}

test "markdown: escape prefixes split at a source newline stay consumed" {
    var r = Renderer.init(test_alloc);
    defer r.deinit();

    // The CSI eats its parameters across the break; the orphan "[3"
    // and "1m" never become text.
    const csi = try r.render("before \x1b[3\n31m after\n", .{});
    try std.testing.expectEqual(@as(usize, 1), csi.lines.len);
    try expectLineText(test_alloc, csi.lines[0], "before after");

    // An OSC payload that runs past a break swallows the lines it
    // covers, and the text after its terminator returns.
    const osc = try r.render("a \x1b]0;title\nhidden\x07 tail\n", .{});
    try std.testing.expectEqual(@as(usize, 1), osc.lines.len);
    try expectLineText(test_alloc, osc.lines[0], "a tail");
}

test "markdown: returned blocks survive caller source mutation" {
    var r = Renderer.init(test_alloc);
    defer r.deinit();

    var buf: [64]u8 = undefined;
    const src = "# head \x1b]0;title\x07tail\n- item **b**\n";
    @memcpy(buf[0..src.len], src);
    const block = try r.render(buf[0..src.len], .{});
    @memset(buf[0..src.len], 'X'); // the caller reuses or frees its buffer

    try std.testing.expectEqual(@as(usize, 2), block.lines.len);
    try expectLineText(test_alloc, block.lines[0], "head tail");
    try expectLineText(test_alloc, block.lines[1], "- item b");
    // No span borrows the caller's buffer at all.
    const caller: usize = @intFromPtr(buf[0..].ptr);
    for (block.lines) |line| {
        for (line.spans) |span| {
            const inside = @intFromPtr(span.text.ptr) < caller + buf.len and
                @intFromPtr(span.text.ptr) + span.text.len > caller;
            try std.testing.expect(!inside);
        }
    }
}

test "markdown: allocation failure surfaces as OutOfMemory" {
    var failing = std.testing.FailingAllocator.init(test_alloc, .{ .fail_index = 0 });
    var r = Renderer.init(failing.allocator());
    defer r.deinit();
    try std.testing.expectError(error.OutOfMemory, r.render("# hi\n", .{}));
}

test {
    std.testing.refAllDecls(@This());
}
