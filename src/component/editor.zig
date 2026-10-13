//! Editor: a single-line text editor component.
//!
//! State is one line of bytes (`line`), a byte-offset cursor (`cursor`)
//! that always sits on a grapheme-cluster boundary, a scroll window
//! (`scroll_col`) in display columns, a bounded stack of full-line undo
//! snapshots, and a bounded Emacs-style kill ring with yank/yank-pop.
//! There is no selection model: every operation acts at the cursor.
//!
//! Width and segmentation come exclusively from `width.zig`. Motion and deletion
//! use Unicode grapheme boundaries (`firstGraphemeLen`); the draw window and cursor
//! use terminal cell clusters (`firstCellLen`, `graphemeWidth`) under its selected
//! policy. Neither path splits a UTF-8 codepoint or a wide cell.
//!
//! Allocation and ownership. `init` stores the `gpa` it is given and
//! every later allocation comes from it; `deinit` frees into it without
//! releasing it, so that allocator must stay alive until the editor is
//! released. The editor owns the line, every undo snapshot and every
//! kill-ring entry in it, and has one owner: a copy names the same
//! storage, so a second `deinit` — including one through a copy —
//! frees the same bytes twice.
//!
//! Line growth is `std.ArrayList`'s and capacity never shrinks, so
//! `Options.initial_capacity` sets how far typing grows nothing, and
//! `clear` keeps what the line already reserved. Recording is the other
//! half of that: with `undo_depth > 0`, each `insert`/`paste` that keeps
//! a byte, each `backspace`/`deleteForward`/`clear` with something to
//! remove, each kill that has bytes to kill, and each `yank`/`yankPop`
//! that inserts text, dupes the whole line once for its snapshot; a kill
//! with `kill_ring_depth > 0` also copies the killed bytes into the
//! ring. The undo stack and the ring grow their own element buffers as
//! they fill; `undo_depth = 0` takes the per-edit line copy out of all
//! of them. `yank` and `yankPop` reserve room in the line before they
//! edit. Motion, `scrollTo`, `undo` and the inspection methods
//! allocate nothing.
//!
//! Failure. Every editing operation reserves what it needs before it
//! edits the line, so `error.OutOfMemory` leaves the line, the cursor
//! and the undo stack holding what they held before the call. That is a
//! claim about content, not about storage: `yank` and `yankPop` reserve
//! the line before the snapshot, so a failure at the snapshot can have
//! moved the line's bytes, and `insert` grows the undo stack's element
//! buffer before it grows the line. The operations that end the
//! kill/yank sequence end it before that reservation, so a failed edit
//! can still close an open sequence; each method says whether it does.
//!
//! Borrowed cells. `draw` draws straight from `line`: a rendered cell
//! does borrow the editor's storage, and it stays sound because the
//! renderer owns the previous frame's text instead of comparing against
//! the app's bytes. `Region` snapshots every drawn cell before it stages
//! a frame, so an in-place edit, a reallocation, or a repaint that follows
//! one can never make the last frame's cells read as the new content.
//! `draw` therefore allocates nothing and copies nothing.
//!
//! Single-line invariant: the line holds only storable codepoints —
//! never C0, DEL, C1, or a byte that does not decode as UTF-8. `insert`
//! (and `paste`, its bracketed-paste entry point) drop them, and the drop
//! is a codepoint decision, not a byte test: a multi-byte character is
//! copied whole or not at all. This is a terminal-safety property, not
//! cosmetics: `Buffer.writeRow` emits a cell's grapheme verbatim, so a
//! stored raw 0x9B would reach the terminal as CSI and a stored ESC
//! would end the row. Tabs and newlines drop here like any other control.
//!
//! Dropped bytes are dropped: nothing normalizes or repairs them (no NFC,
//! no U+FFFD substitution), and a chunk of nothing but control bytes
//! inserts nothing and adds no undo step.
//!
//! `markdown.Sanitizer` is the library's escape-sequence machine for
//! multi-line untrusted text: it lets tab and newline through as
//! structure and consumes a whole escape sequence. The editor needs the
//! opposite on both counts — a single line holds no structure, and the
//! text after a dropped ESC is ordinary content here — so it
//! classifies codepoints locally instead. Same safety rule: no C0, DEL,
//! C1 or invalid byte is ever stored, whichever path classifies it.
//!
//! Chunk boundaries never split a UTF-8 sequence: `input.Reader` holds a
//! truncated tail back and reassembles it before decode, so every
//! `insert`/`paste` argument holds whole characters.
//!
//! Motion cannot allocate, so it cannot fail: motion returns `void`, not
//! an empty error union. The fallible operations return `Error`.

const std = @import("std");
const Buffer = @import("../buffer.zig").Buffer;
const Style = @import("../style.zig").Style;
const Width = @import("../width.zig");
const event = @import("../event.zig");
const Event = event.Event;
const Key = event.Key;
const Clock = @import("component.zig").Clock;
// Imported for the terminal-output regression tests only: the sanitizer
// claim is about the bytes a Region renders, not about the internal line.
const Region = @import("../region.zig").Region;

/// Errors an editor operation can raise: the editor's allocator refused
/// to copy the line, a killed run, or to grow the line, the undo stack
/// or the kill ring. Nothing else fails — width and grapheme handling
/// never error — and every method states what survives the failure.
pub const Error = error{OutOfMemory};

/// Undo snapshots retained by default. The bound is what keeps the
/// stack user-input-driven memory in check: each snapshot is a full copy
/// of the line, so an unbounded stack is an unbounded allocation.
pub const default_undo_depth: usize = 100;

/// Kill-ring entries retained by default. Bounded for the same reason:
/// every kill would otherwise pin its bytes for the whole session.
pub const default_kill_ring_depth: usize = 60;

/// Cursor blink half-period; 530 ms is the xterm/readline cadence.
pub const default_blink_ns: u64 = 530 * std.time.ns_per_ms;

/// Configuration for `Editor.init`. The defaults assume a hand-typed
/// interactive prompt: a short line typed by hand, and a bounded undo
/// stack and kill ring.
pub const Options = struct {
    /// Bytes reserved for the line up front. Size it for the expected
    /// prompt: typing within it grows the line's storage not at all, and
    /// `clear` keeps what is reserved. The reservation covers the line
    /// only — a recorded undo step still dupes the whole line.
    initial_capacity: usize = 64,
    /// Undo snapshots retained; the oldest is dropped when full. 0
    /// records no snapshot, so an editor created with it starts with an
    /// empty undo stack and `undo` always returns false, and it takes
    /// the per-edit line copy out of every operation. Lowering
    /// `Editor.undo_depth` on a live editor only stops new snapshots;
    /// the retained ones stay readable.
    undo_depth: usize = default_undo_depth,
    /// Kill-ring entries retained; the oldest is dropped when full. 0
    /// keeps kills out of the ring: the line is still edited and the
    /// killed bytes are not retained, so an editor created with it
    /// starts with an empty ring and `yank` always returns false.
    /// Lowering `Editor.kill_ring_depth` on a live editor only stops
    /// new entries; `yank` and `yankPop` still read the retained ones.
    kill_ring_depth: usize = default_kill_ring_depth,
    /// Nanoseconds between cursor blink phase toggles; 0 disables blinking
    /// (the cursor stays visible).
    blink_ns: u64 = default_blink_ns,
    /// Style for the line text.
    style: Style = .{},
    /// Style for the cursor marker cell (default: reverse video).
    cursor_style: Style = .{ .attrs = .{ .reverse = true } },
};

/// One undo step: the whole line plus the cursor, captured before a
/// destructive operation.
const Snapshot = struct {
    bytes: []u8,
    cursor: usize,
};

/// One kill-ring entry: the killed bytes. A consecutive kill accumulates
/// onto the newest entry, prepending when it was a backward kill.
const Kill = struct {
    bytes: std.ArrayList(u8) = .empty,
};

/// A byte range of the line, used to replace the text a previous `yank`
/// inserted when `yankPop` cycles to the next ring entry.
const Span = struct {
    start: usize,
    len: usize,
};

/// One frame's draw window: where the window starts and where the cursor
/// sits. `off` and `col` name the same cluster boundary, so the byte
/// offset and the reported column cannot describe different windows.
const Window = struct {
    /// Byte offset of the window's first cluster in the line.
    off: usize,
    /// Display column of that cluster; this is what `scroll_col` holds.
    col: usize,
    /// Display column of the cursor; never left of `col`.
    cursor_col: usize,
};

/// What the previous operation was; kills accumulate while this reads
/// `.kill`, and yank-pop is only valid while it reads `.yank`.
const Action = enum { none, kill, yank };

/// A single-line text editor: one line of bytes, a cluster-aligned cursor,
/// a bounded undo stack, and a bounded kill ring. It owns the line, every
/// undo snapshot and every kill-ring entry allocated from `gpa`, and has
/// one owner, which calls `deinit` once — a copy is not a second owner,
/// and only the second `deinit` is the defect. See the module docs for
/// the allocation and single-line invariants.
pub const Editor = struct {
    /// The allocator `init` was given, stored for the editor's whole
    /// life: it receives every allocation the editor makes, `deinit`
    /// never releases it, and it must stay alive until that call.
    gpa: std.mem.Allocator,
    /// Style for the line text.
    style: Style = .{},
    /// Style for the cursor marker cell.
    cursor_style: Style = .{ .attrs = .{ .reverse = true } },
    /// Nanoseconds between blink phase toggles; 0 disables blinking.
    blink_ns: u64 = default_blink_ns,
    /// Undo snapshots retained; the oldest is dropped when a commit
    /// exceeds the bound. 0 records no further snapshot — it does not
    /// clear the stack, and `undo` still restores whatever `undo_stack`
    /// already holds. Lowering this at run time frees one snapshot per
    /// later commit rather than truncating at once, so the stack can
    /// stay above the new bound.
    undo_depth: usize = default_undo_depth,
    /// Kill-ring entries retained; the oldest is dropped when a push
    /// exceeds the bound. 0 records no further entry, so a kill edits
    /// the line without retaining the killed bytes; it does not empty
    /// the ring, and `yank` and `yankPop` still read the entries
    /// `kill_ring` already holds. Lowering this at run time drops at
    /// most one entry per later push rather than truncating at once, so
    /// the ring can stay above the new bound.
    kill_ring_depth: usize = default_kill_ring_depth,

    /// The line's bytes. Never contains C0 or DEL bytes (see module docs).
    line: std.ArrayList(u8) = .empty,
    /// Cursor as a byte offset into `line.items`; always on a cluster
    /// boundary (readers clamp it, so a stray write cannot panic).
    cursor: usize = 0,
    /// Display column of the window's left edge, for the caller's status
    /// line. `draw` (and `scrollTo`) keep the cursor inside the window and
    /// the edge on a cluster boundary, so it names the column the first
    /// drawn glyph occupies.
    scroll_col: usize = 0,

    /// Undo snapshots, oldest first.
    undo_stack: std.ArrayList(Snapshot) = .empty,
    /// Kill ring, oldest first; the newest entry is last.
    kill_ring: std.ArrayList(Kill) = .empty,
    /// What the previous operation was; kills accumulate while this
    /// reads `.kill`, and yank-pop is only valid while it reads `.yank`.
    action: Action = .none,
    /// Span of the text the last `yank` inserted, if a yank sequence is
    /// still open.
    yank_span: ?Span = null,

    /// Blink interval index already observed; the phase is the index's
    /// parity, so the cadence follows the clock instead of frame timing.
    blink_index: u64 = 0,
    /// Whether the cursor marker is currently drawn (even intervals).
    visible: bool = true,

    /// Create an editor with `options.initial_capacity` bytes reserved for
    /// the line, and store `gpa` for every later allocation. Fails only if
    /// that reservation fails, and then owns nothing, so there is no
    /// partial editor to release. The returned editor owns its
    /// allocations and is released by exactly one `deinit`.
    pub fn init(gpa: std.mem.Allocator, options: Options) Error!Editor {
        var ed: Editor = .{
            .gpa = gpa,
            .style = options.style,
            .cursor_style = options.cursor_style,
            .blink_ns = options.blink_ns,
            .undo_depth = options.undo_depth,
            .kill_ring_depth = options.kill_ring_depth,
        };
        errdefer ed.line.deinit(gpa);
        try ed.line.ensureTotalCapacity(gpa, options.initial_capacity);
        return ed;
    }

    /// Releases the line, every undo snapshot and every kill-ring entry
    /// into `gpa`. The allocator is not released here and must stay alive
    /// until this call. The editor is unusable afterwards: a second call,
    /// or one through a copy, frees the same bytes again.
    pub fn deinit(self: *Editor) void {
        self.line.deinit(self.gpa);
        for (self.undo_stack.items) |snap| self.gpa.free(snap.bytes);
        self.undo_stack.deinit(self.gpa);
        for (self.kill_ring.items) |*entry| entry.bytes.deinit(self.gpa);
        self.kill_ring.deinit(self.gpa);
        self.* = undefined;
    }

    // Inspection.

    /// The line's bytes, borrowed. The contents change with every
    /// operation that edits the line; the storage itself moves with
    /// `insert`, `paste`, `yank` and `yankPop` — including a `yank` or
    /// `yankPop` that reserves the line and then fails — and is gone
    /// after `deinit`. The cells `draw` leaves in a buffer borrow these
    /// same bytes.
    pub fn text(self: *const Editor) []const u8 {
        return self.line.items;
    }

    /// Display width of the line in terminal cells.
    pub fn textWidth(self: *const Editor) usize {
        return widthUpTo(self.line.items, self.line.items.len);
    }

    /// Display column of the cursor: the width of everything left of it.
    pub fn cursorCol(self: *const Editor) usize {
        return widthUpTo(self.line.items, self.cursorAt());
    }

    // Editing.

    /// Insert `bytes` at the cursor through the sanitizer: bytes that do
    /// not decode to a storable codepoint (invalid UTF-8, C0, DEL, C1) are
    /// dropped, everything else lands verbatim — including multi-byte
    /// characters, which are copied whole. One undo step while
    /// `undo_depth > 0` and a byte survives the sanitizer; none otherwise.
    ///
    /// The kill/yank sequence ends before anything is reserved, so
    /// `error.OutOfMemory` leaves the line, cursor and undo stack
    /// unchanged — a snapshot taken for the failed edit is rolled back —
    /// with that sequence closed. The undo stack's spare capacity may
    /// have grown.
    ///
    /// `bytes` must not alias the editor's own line (`text()`): the gap is
    /// written after the line may have been reallocated.
    pub fn insert(self: *Editor, bytes: []const u8) Error!void {
        self.resetKillSequence();
        self.yank_span = null;

        // Measure first: the line can then be grown once and the accepted
        // bytes filled straight into the gap, with no temporary buffer.
        const keep = storableLen(bytes);
        if (keep == 0) return;

        const pushed = try self.recordUndo();
        const gap = self.line.addManyAt(self.gpa, self.cursorAt(), keep) catch |err| {
            if (pushed) self.discardLastUndo();
            return err;
        };
        copyStorable(bytes, gap);
        self.cursor = self.cursorAt() + keep;
        self.commitUndo();
    }

    /// Insert one bracketed-paste chunk at the cursor, through the same
    /// sanitizer as `insert`. Nothing is repaired here (no NFC, no U+FFFD),
    /// so a multi-line paste lands as its printable text with the control
    /// characters between the lines removed.
    ///
    /// Bracketed paste arrives as ordinary key bytes (the parser consumes
    /// the 200~/201~ markers without an event), so one paste reaches the
    /// editor as a run of calls; each call is its own undo step while
    /// `undo_depth > 0` and its own kill-sequence boundary. A chunk of
    /// nothing but control bytes inserts nothing and adds no undo step.
    /// Everything `insert` states about `error.OutOfMemory` holds here.
    pub fn paste(self: *Editor, bytes: []const u8) Error!void {
        try self.insert(bytes);
    }

    /// Delete the cluster before the cursor (Emacs `backspace`). One undo
    /// step while `undo_depth > 0` and there is a cluster to delete. The
    /// kill/yank sequence ends before the snapshot is reserved, so
    /// `error.OutOfMemory` leaves the line, cursor and undo stack
    /// unchanged with that sequence closed.
    pub fn backspace(self: *Editor) Error!void {
        self.resetKillSequence();
        const at = self.cursorAt();
        if (at == 0) return;
        const start = prevBoundary(self.line.items, at);
        _ = try self.recordUndo();
        self.removeRange(start, at - start);
        self.cursor = start;
        self.yank_span = null;
        self.commitUndo();
    }

    /// Delete the cluster at the cursor (Emacs `delete-char`). One undo
    /// step while `undo_depth > 0` and there is a cluster to delete. The
    /// kill/yank sequence ends before the snapshot is reserved, so
    /// `error.OutOfMemory` leaves the line, cursor and undo stack
    /// unchanged with that sequence closed.
    pub fn deleteForward(self: *Editor) Error!void {
        self.resetKillSequence();
        const at = self.cursorAt();
        if (at >= self.line.items.len) return;
        const end = nextBoundary(self.line.items, at);
        _ = try self.recordUndo();
        self.removeRange(at, end - at);
        self.yank_span = null;
        self.commitUndo();
    }

    /// Reset the line to empty (what an app does after submit) and drop
    /// the scroll window. One undo step when `undo_depth > 0` and the line
    /// held anything. The kill/yank sequence and `scroll_col` are reset
    /// before the snapshot is reserved, so `error.OutOfMemory` leaves the
    /// line, cursor and undo stack unchanged with the sequence closed and
    /// the window back at column 0.
    pub fn clear(self: *Editor) Error!void {
        self.resetKillSequence();
        self.yank_span = null;
        self.scroll_col = 0;
        if (self.line.items.len == 0) {
            self.cursor = 0;
            return;
        }
        _ = try self.recordUndo();
        self.line.clearRetainingCapacity();
        self.cursor = 0;
        self.commitUndo();
    }

    // Motion.

    /// Move one cluster left.
    pub fn moveLeft(self: *Editor) void {
        self.resetKillSequence();
        const at = self.cursorAt();
        if (at == 0) return;
        self.cursor = prevBoundary(self.line.items, at);
    }

    /// Move one cluster right.
    pub fn moveRight(self: *Editor) void {
        self.resetKillSequence();
        const at = self.cursorAt();
        if (at >= self.line.items.len) return;
        self.cursor = nextBoundary(self.line.items, at);
    }

    /// Move to the start of the previous word: skip whitespace clusters,
    /// then non-whitespace clusters.
    pub fn moveWordLeft(self: *Editor) void {
        self.resetKillSequence();
        self.cursor = self.wordStartBefore();
    }

    /// Move past the end of the next word: skip whitespace clusters, then
    /// non-whitespace clusters.
    pub fn moveWordRight(self: *Editor) void {
        self.resetKillSequence();
        self.cursor = self.wordEndAfter();
    }

    /// Move to the start of the line.
    pub fn moveHome(self: *Editor) void {
        self.resetKillSequence();
        self.cursor = 0;
    }

    /// Move to the end of the line.
    pub fn moveEnd(self: *Editor) void {
        self.resetKillSequence();
        self.cursor = self.line.items.len;
    }

    // Kills and the kill ring.

    /// Kill from the cursor to the end of the line (ctrl-k). One undo
    /// step while `undo_depth > 0` and there is something to kill.
    /// `error.OutOfMemory` leaves the line, cursor, undo stack contents,
    /// ring and kill/yank sequence as they were; the undo stack's spare
    /// capacity may have grown. The ring is left whole: its push copies
    /// the killed bytes into the new entry before it drops anything, and
    /// dropping the oldest entry frees no capacity, so the append that
    /// follows still fits in what the ring already had and cannot fail.
    pub fn killToEnd(self: *Editor) Error!void {
        try self.killRange(self.cursorAt(), self.line.items.len, true);
    }

    /// Kill from the start of the line to the cursor (ctrl-u). One undo
    /// step while `undo_depth > 0` and there is something to kill.
    /// `error.OutOfMemory` leaves the line, cursor, undo stack contents,
    /// ring and kill/yank sequence as they were; the undo stack's spare
    /// capacity may have grown. The ring is left whole: its push copies
    /// the killed bytes into the new entry before it drops anything, and
    /// dropping the oldest entry frees no capacity, so the append that
    /// follows still fits in what the ring already had and cannot fail.
    pub fn killToStart(self: *Editor) Error!void {
        try self.killRange(0, self.cursorAt(), false);
    }

    /// Kill the word before the cursor: whitespace first, then the word
    /// (ctrl-w, alt-backspace). One undo step while `undo_depth > 0` and
    /// there is something to kill. `error.OutOfMemory` leaves the line,
    /// cursor, undo stack contents, ring and kill/yank sequence as they
    /// were; the undo stack's spare capacity may have grown. The ring is
    /// left whole: its push copies the killed bytes into the new entry
    /// before it drops anything, and dropping the oldest entry frees no
    /// capacity, so the append that follows still fits in what the ring
    /// already had and cannot fail.
    pub fn killWordBefore(self: *Editor) Error!void {
        try self.killRange(self.wordStartBefore(), self.cursorAt(), false);
    }

    /// Kill from the cursor to the end of the next word (alt-d). One undo
    /// step while `undo_depth > 0` and there is something to kill.
    /// `error.OutOfMemory` leaves the line, cursor, undo stack contents,
    /// ring and kill/yank sequence as they were; the undo stack's spare
    /// capacity may have grown. The ring is left whole: its push copies
    /// the killed bytes into the new entry before it drops anything, and
    /// dropping the oldest entry frees no capacity, so the append that
    /// follows still fits in what the ring already had and cannot fail.
    pub fn killWordForward(self: *Editor) Error!void {
        try self.killRange(self.cursorAt(), self.wordEndAfter(), true);
    }

    /// Insert the newest kill at the cursor (ctrl-y) and open a yank
    /// sequence. Returns false when the ring holds nothing. One undo step
    /// while `undo_depth > 0`. The kill/yank sequence ends before the line
    /// is reserved, so `error.OutOfMemory` leaves the line, cursor, undo
    /// stack and ring holding what they held with that sequence closed —
    /// but that reservation runs first, so a failure at the snapshot may
    /// have moved the line's bytes, and bytes borrowed from `text()`
    /// before the call do not survive it.
    pub fn yank(self: *Editor) Error!bool {
        self.resetKillSequence();
        if (self.kill_ring.items.len == 0) return false;
        const newest = &self.kill_ring.items[self.kill_ring.items.len - 1];
        if (newest.bytes.items.len == 0) return false;

        try self.line.ensureUnusedCapacity(self.gpa, newest.bytes.items.len);
        _ = try self.recordUndo();
        const start = self.cursorAt();
        self.insertRaw(newest.bytes.items);
        self.yank_span = .{ .start = start, .len = self.cursor - start };
        self.action = .yank;
        self.commitUndo();
        return true;
    }

    /// Replace the text the last `yank` inserted with the next-older ring
    /// entry (alt-y). Valid only while the yank sequence is open — any
    /// other operation ends it, exactly like readline. Returns false when
    /// there is nothing to cycle. One undo step while `undo_depth > 0`.
    /// The line is reserved before anything else is touched, so
    /// `error.OutOfMemory` leaves the line, cursor, undo stack, ring and
    /// yank sequence holding exactly what they held — that reservation
    /// runs first too, so a failure at the snapshot may have moved the
    /// line's bytes, and bytes borrowed from `text()` before the call do
    /// not survive it.
    pub fn yankPop(self: *Editor) Error!bool {
        if (self.action != .yank) return false;
        if (self.kill_ring.items.len <= 1) return false;
        const span = self.yank_span orelse return false;
        if (span.start + span.len > self.line.items.len) return false;

        const next = self.kill_ring.items[self.kill_ring.items.len - 2].bytes.items;
        try self.line.ensureTotalCapacity(self.gpa, self.line.items.len - span.len + next.len);
        _ = try self.recordUndo();
        self.removeRange(span.start, span.len);
        self.cursor = span.start;
        self.ringRotate();
        self.insertRaw(next);
        self.yank_span = .{ .start = span.start, .len = self.cursor - span.start };
        self.action = .yank;
        self.commitUndo();
        return true;
    }

    // Undo.

    /// Restore the line and cursor from the most recent snapshot. Returns
    /// false when no snapshot is left. Restoring never allocates — the
    /// line's capacity only grows — so no path here can fail; the error
    /// union is kept for uniformity with `yank` and `yankPop`. The
    /// kill/yank sequence ends either way.
    pub fn undo(self: *Editor) Error!bool {
        self.resetKillSequence();
        self.yank_span = null;
        const snap = self.undo_stack.pop() orelse return false;
        defer self.gpa.free(snap.bytes);
        self.line.clearRetainingCapacity();
        self.line.appendSliceAssumeCapacity(snap.bytes);
        self.cursor = @min(snap.cursor, self.line.items.len);
        return true;
    }

    // Input mapping.

    /// Map an input event to an editor operation; true when the editor
    /// consumed it. Unmapped events (`enter`, `tab`, `escape`, arrows the
    /// caller may want for history, every non-key event) return false.
    /// On `error.OutOfMemory` the editor is left in the state the bound
    /// operation documents.
    ///
    /// Bindings:
    /// left/ctrl-b and right/ctrl-f move one cluster, alt/ctrl+arrow and
    /// alt-b/alt-f move one word, home/ctrl-a and end/ctrl-e go to the
    /// line ends, backspace deletes backward, delete and ctrl-d delete
    /// forward (ctrl-d at the end of the line is left to the caller, the
    /// readline EOF convention), ctrl-w and alt-backspace kill a word
    /// backward, alt-d kills a word forward, ctrl-u and ctrl-k kill to the
    /// line ends, ctrl-y yanks, alt-y yank-pops, ctrl-underscore,
    /// ctrl-minus and ctrl-z undo, and any remaining printable key
    /// inserts its text.
    pub fn key(self: *Editor, ev: Event) Error!bool {
        return switch (ev) {
            .paste => |bytes| {
                try self.paste(bytes);
                return true;
            },
            .key_press => |k| self.keyPress(k),
            else => false,
        };
    }

    fn keyPress(self: *Editor, k: Key) Error!bool {
        if (k.isModifier()) return false;

        if (k.matches(Key.left, .{})) {
            self.moveLeft();
            return true;
        }
        if (k.matches(Key.left, .{ .ctrl = true }) or k.matches(Key.left, .{ .alt = true })) {
            self.moveWordLeft();
            return true;
        }
        if (k.matches(Key.right, .{})) {
            self.moveRight();
            return true;
        }
        if (k.matches(Key.right, .{ .ctrl = true }) or k.matches(Key.right, .{ .alt = true })) {
            self.moveWordRight();
            return true;
        }
        if (k.matches('b', .{ .ctrl = true })) {
            self.moveLeft();
            return true;
        }
        if (k.matches('f', .{ .ctrl = true })) {
            self.moveRight();
            return true;
        }
        if (k.matches('b', .{ .alt = true })) {
            self.moveWordLeft();
            return true;
        }
        if (k.matches('f', .{ .alt = true })) {
            self.moveWordRight();
            return true;
        }
        if (k.matches(Key.home, .{}) or k.matches('a', .{ .ctrl = true })) {
            self.moveHome();
            return true;
        }
        if (k.matches(Key.end, .{}) or k.matches('e', .{ .ctrl = true })) {
            self.moveEnd();
            return true;
        }

        if (k.matches(Key.backspace, .{})) {
            try self.backspace();
            return true;
        }
        if (k.matches(Key.delete, .{}) or k.matches('d', .{ .ctrl = true })) {
            // At the line end there is nothing to delete; the caller may
            // treat ctrl-d as EOF (readline), so leave it unconsumed.
            if (self.cursorAt() >= self.line.items.len) return false;
            try self.deleteForward();
            return true;
        }
        if (k.matches('w', .{ .ctrl = true }) or
            k.matches(Key.backspace, .{ .ctrl = true }) or
            k.matches(Key.backspace, .{ .alt = true }))
        {
            try self.killWordBefore();
            return true;
        }
        if (k.matches('d', .{ .alt = true }) or k.matches(Key.delete, .{ .alt = true })) {
            try self.killWordForward();
            return true;
        }
        if (k.matches('u', .{ .ctrl = true })) {
            try self.killToStart();
            return true;
        }
        if (k.matches('k', .{ .ctrl = true })) {
            try self.killToEnd();
            return true;
        }
        if (k.matches('y', .{ .ctrl = true })) {
            _ = try self.yank();
            return true;
        }
        if (k.matches('y', .{ .alt = true })) {
            _ = try self.yankPop();
            return true;
        }
        if (k.matches(0x1F, .{}) or // ctrl-underscore / ctrl-minus
            k.matches('_', .{ .ctrl = true }) or
            k.matches('-', .{ .ctrl = true }) or
            k.matches('z', .{ .ctrl = true }))
        {
            _ = try self.undo();
            return true;
        }

        // Printable text. Shift and caps-lock are part of the character;
        // any other modifier means the key was a command, not text.
        const mods = k.mods;
        if (mods.ctrl or mods.alt or mods.super or mods.hyper or mods.meta) return false;
        if (k.text) |t| {
            if (t.len == 0) return false;
            try self.insert(t);
            return true;
        }
        if (k.codepoint < 0x20 or k.codepoint == 0x7F) return false;
        // Kitty reports its own keys as codepoints in the private-use
        // block (`Key.insert` and up). Those name keys, never text:
        // encoding one would type an unprintable U+E0xx glyph.
        if (k.codepoint >= Key.insert) return false;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(k.codepoint, &buf) catch return false;
        try self.insert(buf[0..n]);
        return true;
    }

    // Presentation.

    /// Keep the cursor inside a window of `viewport` columns: scroll when
    /// it reaches the right edge, and never past the end of the line (the
    /// window may end one column past the line so the end-of-line cursor
    /// stays visible). The edge lands on a cluster boundary, so the column
    /// reported here is the one the first drawn glyph occupies. Callers
    /// can call this with the real terminal width before reading
    /// `scroll_col` for a status line.
    pub fn scrollTo(self: *Editor, viewport: usize) void {
        if (viewport == 0) return;
        _ = self.selectWindow(viewport);
    }

    /// Advance the blink to `now` WITHOUT drawing; true when the phase
    /// changed. The phase is the parity of the absolute interval index, so
    /// the cadence follows the clock rather than frame timing, and calling
    /// twice with the same `now` never toggles twice.
    pub fn advance(self: *Editor, now: Clock) bool {
        if (self.blink_ns == 0) return false;
        const ns: u64 = if (now.nanoseconds <= 0) 0 else @intCast(now.nanoseconds);
        const index = ns / self.blink_ns;
        if (index == self.blink_index) return false;
        self.blink_index = index;
        const phase = index % 2 == 0;
        const changed = phase != self.visible;
        self.visible = phase;
        return changed;
    }

    /// Draw the visible window of the line with the top-left at (x, y):
    /// the text clipped at `buf.width`, plus a cursor marker cell (the
    /// cluster under the cursor, or a space at the end of the line) in
    /// `cursor_style` while the blink phase is on. Columns left of the
    /// window's left edge are skipped; the edge never starts mid-cluster
    /// (a wide cluster straddling it is drawn whole, to its left). Returns
    /// the columns consumed, never more than `buf.width - x`.
    ///
    /// The cells this frame leaves in the buffer borrow `line`, and that is
    /// sound: `Region` owns the previous frame's text, so it compares its
    /// diff against bytes it snapshotted, never against the line the next
    /// edit overwrites or reallocates. Draw, render and the line stay
    /// alive across a frame. Allocates nothing and copies nothing, and it
    /// cannot fail: every cell goes through `Buffer.set`, whose error set
    /// is empty.
    pub fn draw(self: *Editor, buf: *Buffer, x: u16, y: u16, now: Clock) Error!u16 {
        _ = self.advance(now);
        if (y >= buf.height) return 0;
        const avail: usize = buf.width -| x;
        if (avail == 0) return 0;

        // Use the snapped window edge for both text and cursor placement;
        // an unsnapped column inside a wide cluster would overwrite text.
        const win = self.selectWindow(avail);
        const start = win.off;
        const window = self.line.items[start..];
        var consumed = try buf.draw(self.style, window, x, y);

        const rel = win.cursor_col - win.col;
        if (rel < avail) {
            const tail = window[self.cursorAt() - start ..];
            const glen = Width.firstCellLen(tail);
            // The cluster under the cursor, or empty at the end of the line
            // (where the marker is a blank block instead).
            const under: []const u8 =
                if (glen > 0 and Width.graphemeWidth(tail[0..glen]) > 0) tail[0..glen] else "";
            const col = x + @as(u16, @intCast(rel));
            if (self.visible) {
                const marker = if (under.len > 0) under else " ";
                const mw = try buf.draw(self.cursor_style, marker, col, y);
                consumed = @max(consumed, mw + @as(u16, @intCast(rel)));
            } else if (under.len > 0) {
                // Repaint in the line style: a hidden phase must not leave
                // the previous frame's highlight in a diffed buffer.
                _ = try buf.draw(self.style, under, col, y);
            } else {
                try buf.set(col, y, .{}); // the end-of-line block goes blank
            }
        }
        return consumed;
    }

    // Internals.

    /// The cursor clamped into the line (the field is public, so readers
    /// clamp instead of trusting it).
    fn cursorAt(self: *const Editor) usize {
        return @min(self.cursor, self.line.items.len);
    }

    /// Measure cursor and total width together, then snap the window edge
    /// forward to a whole cluster. Record that edge in `scroll_col` and
    /// return its byte offset and column together. Allocates nothing.
    fn selectWindow(self: *Editor, viewport: usize) Window {
        const line = self.line.items;
        const cursor = self.cursorAt();
        var scan: usize = 0;
        var ccol: usize = 0;
        var total: usize = 0;
        while (scan < line.len) {
            const glen = Width.firstCellLen(line[scan..]);
            if (glen == 0) break;
            const w = Width.graphemeWidth(line[scan..][0..glen]);
            const columns: usize = if (w > 0) @intCast(w) else 0;
            total += columns;
            if (scan + glen <= cursor) ccol += columns;
            scan += glen;
        }
        var col = self.scroll_col;
        if (ccol < col) col = ccol;
        if (ccol >= col + viewport) col = ccol + 1 - viewport;
        const max_scroll = if (total + 1 > viewport) total + 1 - viewport else 0;
        if (col > max_scroll) col = max_scroll;

        // Step cluster by cluster until the window has covered `col`, and
        // take the column from the offset: the edge is where a whole
        // cluster begins, never inside one, so the reported column is the
        // one the first drawn glyph occupies. A wide cluster straddling
        // `col` is stepped over and drawn whole to the LEFT of the window
        // rather than hanging half out of it, and the cursor — always at
        // or after `col` — keeps its cell inside the window. A zero-width
        // cluster covers no column, so it travels with the window instead
        // of being stepped over.
        var off: usize = 0;
        var walked: usize = 0;
        while (off < line.len and walked < col) {
            const glen = Width.firstCellLen(line[off..]);
            if (glen == 0) break;
            const w = Width.graphemeWidth(line[off..][0..glen]);
            const wu: usize = if (w > 0) @intCast(w) else 0;
            walked += wu;
            off += glen;
        }
        self.scroll_col = walked;
        return .{ .off = off, .col = walked, .cursor_col = ccol };
    }

    /// End the kill/yank sequence (`pi-tui` `#resetKillSequence`).
    fn resetKillSequence(self: *Editor) void {
        self.action = .none;
    }

    /// Insert already filtered ring bytes after the caller reserved capacity.
    fn insertRaw(self: *Editor, bytes: []const u8) void {
        if (bytes.len == 0) return;
        const at = self.cursorAt();
        self.line.insertSliceAssumeCapacity(at, bytes);
        self.cursor = at + bytes.len;
    }

    /// Delete `len` bytes at `start`; never allocates (the range is
    /// removed in place).
    fn removeRange(self: *Editor, start: usize, len: usize) void {
        self.line.replaceRangeAssumeCapacity(start, len, &.{});
    }

    /// Stage an undo step. Keep the oldest step until the edit succeeds.
    fn recordUndo(self: *Editor) Error!bool {
        if (self.undo_depth == 0) return false;
        const bytes = try self.gpa.dupe(u8, self.line.items);
        errdefer self.gpa.free(bytes);
        try self.undo_stack.append(self.gpa, .{ .bytes = bytes, .cursor = self.cursorAt() });
        return true;
    }

    /// Evict only after the edit's last fallible step has succeeded.
    fn commitUndo(self: *Editor) void {
        if (self.undo_stack.items.len <= self.undo_depth) return;
        const oldest = self.undo_stack.orderedRemove(0);
        self.gpa.free(oldest.bytes);
    }

    /// Drop the snapshot `recordUndo` just took (an operation failed after
    /// it, so there is nothing to undo).
    fn discardLastUndo(self: *Editor) void {
        const snap = self.undo_stack.pop() orelse return;
        self.gpa.free(snap.bytes);
    }

    /// The offset `moveWordLeft` would land on, computed without mutating.
    fn wordStartBefore(self: *const Editor) usize {
        var at = self.cursorAt();
        while (at > 0) {
            const start = prevBoundary(self.line.items, at);
            if (!isSpaceCluster(self.line.items, start, at)) break;
            at = start;
        }
        while (at > 0) {
            const start = prevBoundary(self.line.items, at);
            if (isSpaceCluster(self.line.items, start, at)) break;
            at = start;
        }
        return at;
    }

    /// The offset `moveWordRight` would land on, computed without mutating.
    fn wordEndAfter(self: *const Editor) usize {
        var at = self.cursorAt();
        while (at < self.line.items.len and isSpaceAt(self.line.items, at)) {
            at = nextBoundary(self.line.items, at);
        }
        while (at < self.line.items.len and !isSpaceAt(self.line.items, at)) {
            at = nextBoundary(self.line.items, at);
        }
        return at;
    }

    /// Shared body of the four kill operations: copy the killed bytes into
    /// the ring, snapshot the line, then remove the range in place (the
    /// removal cannot fail, so a failed copy leaves the line untouched).
    fn killRange(self: *Editor, start: usize, end: usize, forward: bool) Error!void {
        if (start >= end) {
            self.resetKillSequence();
            return;
        }
        const killed = self.line.items[start..end];
        const pushed = try self.recordUndo();
        if (self.kill_ring_depth > 0) {
            self.killRingPush(killed, forward) catch |err| {
                if (pushed) self.discardLastUndo();
                return err;
            };
        }
        self.removeRange(start, end - start);
        self.cursor = start;
        self.yank_span = null;
        self.action = .kill;
        self.commitUndo();
    }

    /// Add `bytes` to the ring: accumulate onto the newest entry while the
    /// previous operation was a kill (prepending for a backward kill),
    /// otherwise push a new entry and drop the oldest past the bound.
    fn killRingPush(self: *Editor, bytes: []const u8, forward: bool) Error!void {
        if (bytes.len == 0 or self.kill_ring_depth == 0) return;
        if (self.action == .kill and self.kill_ring.items.len > 0) {
            const newest = &self.kill_ring.items[self.kill_ring.items.len - 1];
            if (forward) {
                try newest.bytes.appendSlice(self.gpa, bytes);
            } else {
                try newest.bytes.insertSlice(self.gpa, 0, bytes);
            }
            return;
        }
        var entry: Kill = .{};
        errdefer entry.bytes.deinit(self.gpa);
        try entry.bytes.appendSlice(self.gpa, bytes);
        if (self.kill_ring.items.len >= self.kill_ring_depth) {
            var oldest = self.kill_ring.orderedRemove(0);
            oldest.bytes.deinit(self.gpa);
        }
        try self.kill_ring.append(self.gpa, entry);
    }

    /// Move the newest entry to the front of the ring, which makes the
    /// next-oldest the current one (`pi-tui` kill-ring.ts `rotate`).
    fn ringRotate(self: *Editor) void {
        if (self.kill_ring.items.len <= 1) return;
        const last = self.kill_ring.pop() orelse return;
        self.kill_ring.insertAssumeCapacity(0, last);
    }
};

// Cluster helpers.

/// Byte offset of the last cluster boundary strictly before `at`
/// (`at` itself must be a boundary).
fn prevBoundary(line: []const u8, at: usize) usize {
    var prev: usize = 0;
    var off: usize = 0;
    while (off < at) {
        const glen = Width.firstGraphemeLen(line[off..]);
        if (glen == 0 or off + glen > at) break; // invalid tail or mid-cluster
        off += glen;
        if (off < at) prev = off;
    }
    return prev;
}

/// Byte offset of the cluster boundary strictly after `at`, or the line
/// end.
fn nextBoundary(line: []const u8, at: usize) usize {
    if (at >= line.len) return line.len;
    const glen = Width.firstGraphemeLen(line[at..]);
    if (glen == 0) return line.len;
    return at + glen;
}

/// Display width of the clusters in `line[0..at]`.
fn widthUpTo(line: []const u8, at: usize) usize {
    var width: usize = 0;
    var off: usize = 0;
    while (off < at) {
        const glen = Width.firstCellLen(line[off..]);
        if (glen == 0 or off + glen > at) break;
        const w = Width.graphemeWidth(line[off..][0..glen]);
        if (w > 0) {
            const wu: usize = @intCast(w);
            width += wu;
        }
        off += glen;
    }
    return width;
}

/// Whitespace as a cluster: the base codepoint decides (a trailing
/// combining mark cannot turn a space into a word).
fn isSpaceCluster(line: []const u8, start: usize, end: usize) bool {
    if (start >= end) return false;
    return isSpaceAt(line, start);
}

/// Whitespace as the cluster beginning at `at`.
fn isSpaceAt(line: []const u8, at: usize) bool {
    if (at >= line.len) return false;
    const glen = Width.firstGraphemeLen(line[at..]);
    if (glen == 0) return false;
    const gc = line[at..][0..glen];
    const n = std.unicode.utf8ByteSequenceLength(gc[0]) catch return false;
    const seq_len: usize = n;
    if (seq_len > gc.len) return false;
    const cp = (switch (seq_len) {
        1 => @as(u21, gc[0]),
        2 => std.unicode.utf8Decode2(gc[0..2].*),
        3 => std.unicode.utf8Decode3(gc[0..3].*),
        4 => std.unicode.utf8Decode4(gc[0..4].*),
        else => unreachable,
    }) catch return false;
    return isSpaceCp(cp);
}

/// Unicode White_Space, so word motion treats a non-breaking or
/// ideographic space as a break like a plain one.
fn isSpaceCp(cp: u21) bool {
    return switch (cp) {
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0 => true,
        0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// What the sanitizer decides about one UTF-8 sequence at the head of the
/// input: `len` bytes are accepted (copied verbatim), and `step` bytes are
/// consumed so the scan always makes progress. A byte that cannot start a
/// sequence (a stray continuation or a truncated tail) drops one byte at a
/// time; a control codepoint drops its whole sequence.
const Storable = struct { len: usize, step: usize };

fn classify(bytes: []const u8) Storable {
    const n = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return .{ .len = 0, .step = 1 };
    const seq_len: usize = n;
    if (seq_len > bytes.len) return .{ .len = 0, .step = 1 };
    const cp = (switch (seq_len) {
        1 => @as(u21, bytes[0]),
        2 => std.unicode.utf8Decode2(bytes[0..2].*),
        3 => std.unicode.utf8Decode3(bytes[0..3].*),
        4 => std.unicode.utf8Decode4(bytes[0..4].*),
        else => unreachable,
    }) catch return .{ .len = 0, .step = 1 };
    return .{ .len = if (isControlCp(cp)) 0 else seq_len, .step = seq_len };
}

/// Bytes of `bytes` that may be stored in the line.
fn storableLen(bytes: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const part = classify(bytes[i..]);
        total += part.len;
        i += part.step;
    }
    return total;
}

/// Copy the storable bytes of `bytes` into `out`, which must already hold
/// `storableLen(bytes)` bytes.
fn copyStorable(bytes: []const u8, out: []u8) void {
    var n: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const part = classify(bytes[i..]);
        if (part.len > 0) {
            @memcpy(out[n..][0..part.len], bytes[i..][0..part.len]);
            n += part.len;
        }
        i += part.step;
    }
}

/// Codepoints that must never reach the terminal as text: C0 (which would
/// end the line or move the cursor), DEL, and C1 (0x80..0x9F — CSI, the
/// raw 0x9B form of a terminal control). `Buffer.writeRow` emits a cell's
/// grapheme verbatim, so dropping them here is what keeps an untrusted
/// paste from steering the terminal.
fn isControlCp(cp: u21) bool {
    return cp < 0x20 or (cp >= 0x7F and cp <= 0x9F);
}

test {
    std.testing.refAllDecls(@This());
}

// Tests.

const test_alloc = std.testing.allocator;

/// The z-g family: 4 + 3 + 4 = 11 bytes in one cluster.
const zwj_family: []const u8 = "\u{1f468}\u{200d}\u{1f33e}";
/// e + COMBINING ACUTE ACCENT: 3 bytes in one cluster.
const e_acute: []const u8 = "e\u{301}";

/// Concatenate one row's graphemes into `out` for test assertions (wide
/// continuations emit nothing, matching the renderer).
fn rowStr(buf: *const Buffer, y: usize, out: []u8) []const u8 {
    var n: usize = 0;
    var x: usize = 0;
    while (x < buf.width) : (x += 1) {
        const cell = buf.get(@intCast(x), @intCast(y));
        if (cell.wide or cell.grapheme.len == 0) continue;
        @memcpy(out[n..][0..cell.grapheme.len], cell.grapheme);
        n += cell.grapheme.len;
    }
    return out[0..n];
}

/// The key event the parser emits for a ground-state key: a printable key
/// carries its text, a special key only its codepoint.
fn press(codepoint: u21) Event {
    return .{ .key_press = .{ .codepoint = codepoint } };
}

/// The same key with modifiers (ctrl+letter, alt+arrow, …).
fn pressMod(codepoint: u21, mods: Key.Modifiers) Event {
    return .{ .key_press = .{ .codepoint = codepoint, .mods = mods } };
}

/// A printable key carrying text, including multi-byte and multi-cluster.
fn pressText(codepoint: u21, bytes: []const u8) Event {
    return .{ .key_press = .{ .codepoint = codepoint, .text = bytes } };
}

test "editor: typing inserts printable text at the cursor" {
    var ed = try Editor.init(test_alloc, .{});
    defer ed.deinit();

    try std.testing.expect(try ed.key(pressText('a', "a")));
    try std.testing.expect(try ed.key(pressText('b', "b")));
    try std.testing.expectEqualStrings("ab", ed.text());
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);

    // ctrl-a goes home, then a typed key lands in front.
    try std.testing.expect(try ed.key(pressMod('a', .{ .ctrl = true })));
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
    try ed.insert("X");
    try std.testing.expectEqualStrings("Xab", ed.text());
    try std.testing.expectEqual(@as(usize, 1), ed.cursor);
}

test "editor: motion never splits a combining-mark cluster" {
    var ed = try Editor.init(test_alloc, .{});
    defer ed.deinit();
    // "e" + COMBINING ACUTE is one three-byte cluster, then "x": the only
    // boundaries in the line are 0, 3 and 4.
    try ed.insert(e_acute ++ "x");

    try std.testing.expectEqual(@as(usize, 4), ed.cursor);
    try std.testing.expectEqual(@as(usize, 2), ed.cursorCol());

    ed.moveLeft();
    try std.testing.expectEqual(@as(usize, 3), ed.cursor); // before "x"
    try std.testing.expectEqual(@as(usize, 1), ed.cursorCol());

    ed.moveLeft();
    // The whole cluster moves, so the cursor lands on 0 — never on 1 or 2,
    // inside the 2-byte combining mark that extends the "e".
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
    try std.testing.expectEqual(@as(usize, 0), ed.cursorCol());

    ed.moveLeft();
    try std.testing.expectEqual(@as(usize, 0), ed.cursor); // clamped

    ed.moveRight();
    try std.testing.expectEqual(@as(usize, 3), ed.cursor); // over the cluster
    ed.moveRight();
    try std.testing.expectEqual(@as(usize, 4), ed.cursor);
    ed.moveRight();
    try std.testing.expectEqual(@as(usize, 4), ed.cursor); // clamped
}

test "editor: motion and deletion never split a ZWJ family" {
    var ed = try Editor.init(test_alloc, .{});
    defer ed.deinit();
    try ed.insert(zwj_family ++ "x"); // 11 + 1 = 12 bytes, two clusters

    try std.testing.expectEqual(@as(usize, 12), ed.cursor);
    try std.testing.expectEqual(@as(usize, 3), ed.cursorCol()); // 2 + 1 cells

    ed.moveLeft();
    try std.testing.expectEqual(@as(usize, 11), ed.cursor); // before "x"
    ed.moveLeft();
    try std.testing.expectEqual(@as(usize, 0), ed.cursor); // the whole family

    ed.moveEnd();
    try ed.backspace();
    try std.testing.expectEqualStrings(zwj_family, ed.text()); // only "x" went

    ed.moveHome();
    try ed.deleteForward();
    try std.testing.expectEqualStrings("", ed.text()); // all 11 bytes at once
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
}

test "editor: backspace and deleteForward remove whole clusters" {
    var ed = try Editor.init(test_alloc, .{});
    defer ed.deinit();

    try ed.insert(e_acute);
    try ed.backspace();
    try std.testing.expectEqualStrings("", ed.text());

    try ed.insert("x" ++ zwj_family);
    ed.moveHome();
    try ed.deleteForward();
    try std.testing.expectEqualStrings(zwj_family, ed.text());
    try ed.deleteForward();
    try std.testing.expectEqualStrings("", ed.text());

    try ed.backspace(); // empty line: a no-op, not an error
    try std.testing.expectEqualStrings("", ed.text());
    try ed.deleteForward();
    try std.testing.expectEqualStrings("", ed.text());
}

test "editor: word motion stops at word boundaries" {
    var ed = try Editor.init(test_alloc, .{});
    defer ed.deinit();
    try ed.insert("foo bar  baz"); // 12 bytes

    ed.moveWordLeft();
    try std.testing.expectEqual(@as(usize, 9), ed.cursor); // start of "baz"
    ed.moveWordLeft();
    try std.testing.expectEqual(@as(usize, 4), ed.cursor); // over the two spaces
    ed.moveWordLeft();
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
    ed.moveWordLeft();
    try std.testing.expectEqual(@as(usize, 0), ed.cursor); // clamped

    ed.moveWordRight();
    try std.testing.expectEqual(@as(usize, 3), ed.cursor);
    ed.moveWordRight();
    try std.testing.expectEqual(@as(usize, 7), ed.cursor); // end of "bar"
    ed.moveWordRight();
    try std.testing.expectEqual(@as(usize, 12), ed.cursor); // after "baz"
    ed.moveWordRight();
    try std.testing.expectEqual(@as(usize, 12), ed.cursor);
}

test "editor: word motion treats non-breaking space as a break" {
    var ed = try Editor.init(test_alloc, .{});
    defer ed.deinit();
    try ed.insert("a\u{a0}b"); // 1 + 2 + 1 bytes

    ed.moveWordLeft();
    try std.testing.expectEqual(@as(usize, 3), ed.cursor); // start of "b"
    ed.moveWordLeft();
    try std.testing.expectEqual(@as(usize, 0), ed.cursor); // over the NBSP
}

test "editor: killWordBefore kills the word before the cursor" {
    var ed = try Editor.init(test_alloc, .{});
    defer ed.deinit();
    try ed.insert("foo bar");

    try ed.killWordBefore();
    try std.testing.expectEqualStrings("foo ", ed.text());
    try std.testing.expectEqual(@as(usize, 4), ed.cursor);

    try ed.killWordBefore(); // the trailing space goes with the word
    try std.testing.expectEqualStrings("", ed.text());
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);

    try ed.killWordBefore(); // nothing left: a no-op
    try std.testing.expectEqualStrings("", ed.text());

    // The no-op pushed no undo step, so the stack holds exactly the setup
    // insert and the two real kills: three undos empty it, a fourth is out.
    try std.testing.expect(try ed.undo());
    try std.testing.expectEqualStrings("foo ", ed.text());
    try std.testing.expect(try ed.undo());
    try std.testing.expectEqualStrings("foo bar", ed.text());
    try std.testing.expect(try ed.undo());
    try std.testing.expectEqualStrings("", ed.text());
    try std.testing.expect(!try ed.undo());
}

test "editor: killWordForward kills the next word" {
    var ed = try Editor.init(test_alloc, .{});
    defer ed.deinit();
    try ed.insert("foo bar");

    ed.moveHome();
    try ed.killWordForward();
    try std.testing.expectEqualStrings(" bar", ed.text()); // "foo" went
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);

    // The cursor now sits on the space, and word motion skips whitespace
    // before it takes a word (readline forward-word, the rule
    // `moveWordRight` uses), so this kill covers the space as well.
    try ed.killWordForward();
    try std.testing.expectEqualStrings("", ed.text());
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);

    try ed.killWordForward(); // an empty line: a no-op
    try std.testing.expectEqualStrings("", ed.text());
}

test "editor: killToEnd and killToStart cover each side of the cursor" {
    var ed = try Editor.init(test_alloc, .{});
    defer ed.deinit();
    try ed.insert("hello");
    ed.moveHome();
    ed.moveRight();
    ed.moveRight(); // cursor at 2

    try ed.killToEnd();
    try std.testing.expectEqualStrings("he", ed.text());
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);

    try ed.killToStart();
    try std.testing.expectEqualStrings("", ed.text());
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
}

test "editor: consecutive kills accumulate into one ring entry" {
    var ed = try Editor.init(test_alloc, .{});
    defer ed.deinit();
    try ed.insert("one two three");

    try ed.killWordBefore(); // "three", backward
    try ed.killWordBefore(); // "two " prepends -> "two three"
    try std.testing.expectEqualStrings("one ", ed.text());

    try std.testing.expect(try ed.yank());
    try std.testing.expectEqualStrings("one two three", ed.text());
    try std.testing.expectEqual(@as(usize, 13), ed.cursor);
}

test "editor: separate kills cycle with yankPop" {
    var ed = try Editor.init(test_alloc, .{});
    defer ed.deinit();
    try ed.insert("alpha beta gamma"); // 16 bytes

    try ed.killWordBefore(); // ring: ["gamma"], line "alpha beta "
    ed.moveHome(); // motion ends the kill sequence
    try ed.killWordForward(); // ring: ["gamma","alpha"], line " beta "
    try std.testing.expectEqualStrings(" beta ", ed.text());

    try std.testing.expect(try ed.yank()); // newest first: "alpha"
    try std.testing.expectEqualStrings("alpha beta ", ed.text());
    try std.testing.expectEqual(@as(usize, 5), ed.cursor);

    try std.testing.expect(try ed.yankPop()); // next-older: "gamma"
    try std.testing.expectEqualStrings("gamma beta ", ed.text());
    try std.testing.expectEqual(@as(usize, 5), ed.cursor);

    try std.testing.expect(try ed.yankPop()); // wraps back to "alpha"
    try std.testing.expectEqualStrings("alpha beta ", ed.text());

    ed.moveHome(); // any other operation closes the yank sequence
    try std.testing.expect(!try ed.yankPop());
}

test "editor: a refused yank-pop preserves the text and the next ring entry" {
    var ed = try Editor.init(test_alloc, .{ .undo_depth = 0 });
    defer ed.deinit();
    const long = "L" ** 80;
    try ed.insert(long);
    try ed.killToStart();
    try ed.insert("s");
    try ed.killToStart();
    const fill: [256]u8 = @splat('x');
    const prefix_len = ed.line.capacity - 1;
    try ed.insert(fill[0..prefix_len]);
    try std.testing.expect(try ed.yank());
    const before = try test_alloc.dupe(u8, ed.text());
    defer test_alloc.free(before);

    var failing = std.testing.FailingAllocator.init(test_alloc, .{ .fail_index = 0 });
    failing.resize_fail_index = 0;
    ed.gpa = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, ed.yankPop());
    ed.gpa = test_alloc;
    try std.testing.expectEqualStrings(before, ed.text());
    try std.testing.expect(try ed.yankPop());
    try std.testing.expectEqualStrings(long, ed.text()[prefix_len..]);
}

test "editor: yankPop without a prior yank is a no-op" {
    var ed = try Editor.init(test_alloc, .{});
    defer ed.deinit();
    try ed.insert("x");
    try std.testing.expect(!try ed.yankPop());
    try std.testing.expect(!try ed.yank()); // empty ring
    try std.testing.expectEqualStrings("x", ed.text());
}

test "editor: undo restores the state before each destructive op" {
    const Op = enum {
        insert,
        paste,
        backspace,
        delete_forward,
        kill_to_end,
        kill_to_start,
        kill_word_before,
        kill_word_forward,
        yank,
        clear,
    };

    // An explicit table, not `std.enums.values`: the loop is a plain
    // runtime `for` and every `switch` below stays exhaustive.
    const ops = [_]Op{
        .insert,
        .paste,
        .backspace,
        .delete_forward,
        .kill_to_end,
        .kill_to_start,
        .kill_word_before,
        .kill_word_forward,
        .yank,
        .clear,
    };
    for (ops) |op| {
        var ed = try Editor.init(test_alloc, .{});
        defer ed.deinit();
        try ed.insert("alpha beta gamma");

        // Every step the setup pushed: the line's own insert, plus what
        // the operation needs before it. Emptying those below is what makes
        // the final `undo` a proof that the operation pushed exactly one.
        var setup_steps: usize = 1;
        switch (op) {
            // Cursor at the end of the line.
            .insert, .paste, .backspace, .kill_word_before, .kill_to_start, .clear => {},
            // Cursor at the start: only forward deletion has material.
            .delete_forward, .kill_to_end, .kill_word_forward => ed.moveHome(),
            // A non-empty ring, created by an earlier kill of its own.
            .yank => {
                try ed.killWordBefore();
                setup_steps += 1;
            },
        }

        var before: [32]u8 = undefined;
        const before_len = ed.text().len;
        @memcpy(before[0..before_len], ed.text());
        const before_cursor = ed.cursor;

        switch (op) {
            .insert => try ed.insert("X"),
            .paste => try ed.paste("X"),
            .backspace => try ed.backspace(),
            .delete_forward => try ed.deleteForward(),
            .kill_to_end => try ed.killToEnd(),
            .kill_to_start => try ed.killToStart(),
            .kill_word_before => try ed.killWordBefore(),
            .kill_word_forward => try ed.killWordForward(),
            .yank => try std.testing.expect(try ed.yank()),
            .clear => try ed.clear(),
        }

        // The operation must have changed something, else the check is vacuous.
        try std.testing.expect(ed.text().len != before_len or ed.cursor != before_cursor);

        try std.testing.expect(try ed.undo());
        try std.testing.expectEqualStrings(before[0..before_len], ed.text());
        try std.testing.expectEqual(before_cursor, ed.cursor);

        // Exactly one step per destructive operation, and nothing past it.
        var step: usize = 0;
        while (step < setup_steps) : (step += 1) {
            try std.testing.expect(try ed.undo());
        }
        try std.testing.expect(!try ed.undo());
    }
}

test "editor: clear empties the line and is undoable" {
    var ed = try Editor.init(test_alloc, .{});
    defer ed.deinit();
    try ed.insert("hello");
    ed.scroll_col = 3;

    try ed.clear();
    try std.testing.expectEqualStrings("", ed.text());
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
    try std.testing.expectEqual(@as(usize, 0), ed.scroll_col);

    try std.testing.expect(try ed.undo());
    try std.testing.expectEqualStrings("hello", ed.text());
    try std.testing.expectEqual(@as(usize, 5), ed.cursor);

    try ed.clear();
    try ed.clear(); // already empty: no second snapshot
    try std.testing.expect(try ed.undo());
    try std.testing.expectEqualStrings("hello", ed.text());
}

test "editor: undo depth is bounded" {
    var ed = try Editor.init(test_alloc, .{ .undo_depth = 3 });
    defer ed.deinit();

    try ed.insert("a");
    try ed.insert("b");
    try ed.insert("c");
    try ed.insert("d"); // the snapshot before "a" is dropped here

    try std.testing.expectEqual(@as(usize, 3), ed.undo_stack.items.len);
    try std.testing.expect(try ed.undo());
    try std.testing.expectEqualStrings("abc", ed.text());
    try std.testing.expect(try ed.undo());
    try std.testing.expectEqualStrings("ab", ed.text());
    try std.testing.expect(try ed.undo());
    try std.testing.expectEqualStrings("a", ed.text());
    try std.testing.expect(!try ed.undo()); // the oldest state is gone for good
}

test "editor: undo_depth 0 disables undo without breaking editing" {
    var ed = try Editor.init(test_alloc, .{ .undo_depth = 0 });
    defer ed.deinit();
    try ed.insert("hi");
    try ed.backspace();
    try std.testing.expectEqualStrings("h", ed.text());
    try std.testing.expect(!try ed.undo());
}

test "editor: an insert that fails on OOM leaves the line and undo stack intact" {
    var failing = std.testing.FailingAllocator.init(test_alloc, .{});
    var ed = try Editor.init(test_alloc, .{ .initial_capacity = 1, .undo_depth = 3 });
    defer ed.deinit();
    const real = ed.gpa;

    // Fill the line to its capacity so the next insert has to grow it.
    try ed.line.ensureTotalCapacityPrecise(real, 8);
    while (ed.line.items.len < ed.line.capacity) try ed.insert("x");
    const before_len = ed.line.items.len;
    const before_snapshots = ed.undo_stack.items.len;

    // The snapshot allocation (the first since the swap) succeeds; the
    // line growth (the second) fails. The snapshot must be rolled back, so
    // undo never restores a state the failed insert never left.
    failing.fail_index = failing.alloc_index + 1;
    failing.resize_fail_index = failing.resize_index; // remap never sneaks past
    ed.gpa = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, ed.insert("y"));
    ed.gpa = real;

    try std.testing.expectEqual(before_len, ed.line.items.len);
    try std.testing.expectEqual(before_snapshots, ed.undo_stack.items.len);
    for (ed.line.items) |b| try std.testing.expectEqual(@as(u8, 'x'), b);

    // The snapshot itself failing is also a no-op.
    failing.fail_index = failing.alloc_index;
    ed.gpa = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, ed.insert("y"));
    ed.gpa = real;
    try std.testing.expectEqual(before_snapshots, ed.undo_stack.items.len);
    try std.testing.expectEqual(before_len, ed.line.items.len);
    // A rejected edit at the history bound must not evict a valid step.
    var steps: usize = 0;
    while (try ed.undo()) : (steps += 1) {
        try std.testing.expectEqual(before_len - steps - 1, ed.text().len);
    }
    try std.testing.expectEqual(@as(usize, 3), steps);
}

test "editor: the sanitizer drops controls and invalid bytes, keeps the rest" {
    var ed = try Editor.init(test_alloc, .{});
    defer ed.deinit();

    try ed.paste("h\u{e9}llo " ++ zwj_family);
    try std.testing.expectEqualStrings("h\u{e9}llo " ++ zwj_family, ed.text());
    // The cursor is a byte offset, not a column: "héllo " is 7 bytes and
    // the ZWJ family is 11, and the paste dropped nothing.
    try std.testing.expectEqual(@as(usize, 7 + 11), ed.cursor);

    // C0, DEL and ESC never reach the line; the printable tail of an
    // escape sequence is ordinary text.
    ed.moveEnd();
    try ed.paste("a\nb\rc\td\x7f\x1b[31m");
    try std.testing.expectEqualStrings("h\u{e9}llo " ++ zwj_family ++ "abcd[31m", ed.text());

    // C1 controls drop whole, encoded (C2 9B = U+009B) and raw (a bare
    // 0x9B byte, which the seam would otherwise render as U+FFFD and
    // Buffer.writeRow would emit verbatim as CSI).
    try ed.paste("e\xc2\x9bf\x9bg");
    try std.testing.expectEqualStrings("h\u{e9}llo " ++ zwj_family ++ "abcd[31mefg", ed.text());
    try std.testing.expect(std.mem.indexOf(u8, ed.text(), "\x9b") == null);

    // Invalid UTF-8: a lone continuation byte, a truncated sequence and
    // an over-long lead each drop; the surrounding text survives.
    try ed.paste("h\x80i\xffj\xf0\x9f");
    try std.testing.expectEqualStrings("h\u{e9}llo " ++ zwj_family ++ "abcd[31mefghij", ed.text());
    try std.testing.expect(std.unicode.utf8ValidateSlice(ed.text()));

    // Nothing survives, so the line keeps its bytes and the paste adds no
    // undo step.
    const len_before = ed.text().len;
    const steps_before = ed.undo_stack.items.len;
    try ed.paste("\n\r\t");
    try std.testing.expectEqual(len_before, ed.text().len);
    try std.testing.expectEqual(steps_before, ed.undo_stack.items.len);
}

test "editor: a piped Region renders no raw C0, C1 or invalid bytes" {
    // The real pipeline, not a source-text check: an untrusted paste
    // carrying an encoded C1 (U+009B), a raw 0x9B, an ESC sequence and an
    // invalid byte must leave the band as printable text. `interactive =
    // false` is the frame a pipe gets, so the whole band is literal
    // characters: not one escape byte reaches the stream.
    var ed = try Editor.init(test_alloc, .{ .blink_ns = 0, .cursor_style = .{} });
    defer ed.deinit();
    try ed.paste("a\xc2\x9bb\x9bc\x1b[31md\xff");
    // "d" follows the escape sequence in the paste, so it lands after its
    // printable tail: the ESC, the C1 bytes and the invalid byte drop.
    try std.testing.expectEqualStrings("abc[31md", ed.text());

    var r = try Region.init(test_alloc, .{ .height = 1, .interactive = false });
    defer r.deinit();
    _ = try ed.draw(&r.cur, 0, 0, .fromNanoseconds(0));

    var tw: TestWriter = .{};
    tw.init();
    try r.render(&tw.w);

    const out = tw.w.buffered();
    // The printable tail of the pasted escape sequence lands as ordinary
    // characters; the ESC that introduced it, the C1 bytes and the invalid
    // byte do not.
    try std.testing.expect(std.mem.startsWith(u8, out, "abc[31md"));
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b") == null); // no escape at all
    try std.testing.expect(std.mem.indexOf(u8, out, "\x9b") == null); // raw CSI
    try std.testing.expect(std.mem.indexOf(u8, out, "\xc2\x9b") == null); // U+009B
    try std.testing.expect(std.mem.indexOf(u8, out, "\xff") == null);
}

test "editor: Region frames repaint after a same-length edit and a reallocation" {
    // Drawn cells borrow `line`, so the diff's soundness rests on Region
    // owning the previous frame's text. Both hazards below would make the
    // next frame emit nothing while the terminal still shows the old text:
    // an in-place edit of the same length (same pointer, same cursor
    // column, new bytes) and a growth that moves the line while the drawn
    // cells still point into its old storage.
    var ed = try Editor.init(test_alloc, .{ .blink_ns = 0 });
    defer ed.deinit();
    try ed.insert("ab");

    var r = try Region.init(test_alloc, .{ .height = 1, .sync_output = false });
    defer r.deinit();

    var t1: TestWriter = .{};
    t1.init();
    _ = try ed.draw(&r.cur, 0, 0, .fromNanoseconds(0));
    try r.render(&t1.w);
    try std.testing.expect(std.mem.indexOf(u8, t1.w.buffered(), "ab") != null);

    // Same length, same cursor column, different bytes, no reallocation.
    try ed.clear();
    try ed.insert("cd");
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
    var t2: TestWriter = .{};
    t2.init();
    _ = try ed.draw(&r.cur, 0, 0, .fromNanoseconds(0));
    try r.render(&t2.w);
    try std.testing.expect(std.mem.indexOf(u8, t2.w.buffered(), "cd") != null);
    try std.testing.expect(std.mem.indexOf(u8, t2.w.buffered(), "ab") == null);

    // An unchanged frame emits nothing: redrawing the same borrowed bytes
    // is not damage.
    var t3: TestWriter = .{};
    t3.init();
    _ = try ed.draw(&r.cur, 0, 0, .fromNanoseconds(0));
    try r.render(&t3.w);
    try std.testing.expectEqualStrings("", t3.w.buffered());

    // Grow the line past its capacity, so its storage moves while the
    // drawn cells still point into the old block, then repaint the same
    // width: the frame that reaches the terminal carries the new bytes.
    // The growth must leave the bucket the line was carved from — a couple
    // of hundred bytes are absorbed in place, which would leave the
    // premise below unmet and the hazard untested.
    const before = ed.line.items.ptr;
    try ed.insert("x" ** 8192);
    try ed.clear();
    try ed.insert("ef");
    try std.testing.expect(ed.line.items.ptr != before); // the premise

    var t4: TestWriter = .{};
    t4.init();
    _ = try ed.draw(&r.cur, 0, 0, .fromNanoseconds(0));
    try r.render(&t4.w);
    try std.testing.expect(std.mem.indexOf(u8, t4.w.buffered(), "ef") != null);
    try std.testing.expect(std.mem.indexOf(u8, t4.w.buffered(), "cd") == null);
}

test "editor: paste chunks concatenate byte-identically" {
    var ed = try Editor.init(test_alloc, .{});
    defer ed.deinit();

    const whole = "ab\u{e9}" ++ zwj_family ++ "\u{1f600}";
    try ed.insert("ab");
    try ed.paste("\u{e9}");
    try ed.paste(zwj_family);
    try ed.paste("\u{1f600}");
    try std.testing.expectEqualStrings(whole, ed.text());
    try std.testing.expectEqual(whole.len, ed.cursor);
}

test "editor: mixed ASCII/Latin-1/emoji round-trip is byte-identical" {
    var ed = try Editor.init(test_alloc, .{});
    defer ed.deinit();

    // Boundaries: 0, 1, 3, 4, 8, 9, 20, 21.
    const line = "a\u{e9}b\u{1f600}c" ++ zwj_family ++ "d";
    try ed.insert(line);
    try std.testing.expectEqualStrings(line, ed.text());

    // Walk left cluster by cluster and land exactly on every boundary.
    const left = [_]usize{ 20, 9, 8, 4, 3, 1, 0 };
    for (left) |expected| {
        ed.moveLeft();
        try std.testing.expectEqual(expected, ed.cursor);
    }
    const right = [_]usize{ 1, 3, 4, 8, 9, 20, 21 };
    for (right) |expected| {
        ed.moveRight();
        try std.testing.expectEqual(expected, ed.cursor);
    }
    try std.testing.expectEqualStrings(line, ed.text()); // bytes never changed
    try std.testing.expectEqual(line.len, ed.cursor);
}

test "editor: blink phase follows the clock and advance is idempotent" {
    var ed = try Editor.init(test_alloc, .{ .blink_ns = 100 });
    defer ed.deinit();

    try std.testing.expect(!ed.advance(.fromNanoseconds(0))); // visible, phase 0
    try std.testing.expect(ed.visible);
    try std.testing.expect(!ed.advance(.fromNanoseconds(50)));
    try std.testing.expect(ed.advance(.fromNanoseconds(100))); // phase 1: hidden
    try std.testing.expect(!ed.visible);
    try std.testing.expect(!ed.advance(.fromNanoseconds(100))); // same now: no toggle
    try std.testing.expect(!ed.advance(.fromNanoseconds(199)));
    try std.testing.expect(ed.advance(.fromNanoseconds(200))); // phase 2: visible
    try std.testing.expect(ed.visible);
    try std.testing.expect(!ed.advance(.fromNanoseconds(400))); // same parity: no change
    try std.testing.expect(ed.visible);
    try std.testing.expect(ed.advance(.fromNanoseconds(500))); // five intervals: odd
    try std.testing.expect(!ed.visible);

    var off = try Editor.init(test_alloc, .{ .blink_ns = 0 });
    defer off.deinit();
    try std.testing.expect(!off.advance(.fromNanoseconds(1_000_000)));
    try std.testing.expect(off.visible);
}

test "editor: draw renders the line and the cursor marker" {
    var ed = try Editor.init(test_alloc, .{ .blink_ns = 0 });
    defer ed.deinit();
    try ed.insert("ab");
    ed.moveHome();

    var buf = try Buffer.init(test_alloc, 6, 1);
    defer buf.deinit();
    const consumed = try ed.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 2), consumed);
    try std.testing.expectEqualStrings("a", buf.get(0, 0).grapheme);
    try std.testing.expectEqualStrings("b", buf.get(1, 0).grapheme);
    // The marker is the cluster under the cursor, in cursor_style.
    try std.testing.expect(buf.get(0, 0).style.eql(ed.cursor_style));
    try std.testing.expect(!buf.get(1, 0).style.eql(ed.cursor_style));
    try std.testing.expect(buf.get(2, 0).eql(.{}));

    ed.moveEnd();
    _ = try ed.draw(&buf, 0, 0, .fromNanoseconds(0));
    // At the end of the line the marker is a blank cell.
    try std.testing.expectEqualStrings(" ", buf.get(2, 0).grapheme);
    try std.testing.expect(buf.get(2, 0).style.eql(ed.cursor_style));
}

test "editor: a hidden blink phase draws no marker" {
    var ed = try Editor.init(test_alloc, .{ .blink_ns = 100 });
    defer ed.deinit();
    try ed.insert("ab");

    var buf = try Buffer.init(test_alloc, 4, 1);
    defer buf.deinit();
    // t = 0: visible.
    _ = try ed.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expect(buf.get(2, 0).style.eql(ed.cursor_style));

    buf.clear();
    _ = try ed.draw(&buf, 0, 0, .fromNanoseconds(100)); // phase 1: hidden
    var row: [8]u8 = undefined;
    try std.testing.expectEqualStrings("ab  ", rowStr(&buf, 0, &row));
    try std.testing.expect(buf.get(2, 0).eql(.{}));

    // With the cursor over text the hidden phase repaints the line style,
    // so a diffed buffer does not keep the previous highlight.
    ed.moveHome();
    buf.clear();
    _ = try ed.draw(&buf, 0, 0, .fromNanoseconds(100));
    try std.testing.expect(buf.get(0, 0).style.eql(ed.style));
    try std.testing.expect(!buf.get(0, 0).style.eql(ed.cursor_style));
}

test "editor: an empty editor draws just the cursor block" {
    var ed = try Editor.init(test_alloc, .{ .blink_ns = 0 });
    defer ed.deinit();

    var buf = try Buffer.init(test_alloc, 4, 1);
    defer buf.deinit();
    const consumed = try ed.draw(&buf, 1, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 1), consumed);
    try std.testing.expectEqualStrings(" ", buf.get(1, 0).grapheme);
    try std.testing.expect(buf.get(1, 0).style.eql(ed.cursor_style));
    try std.testing.expect(buf.get(0, 0).eql(.{}));
    try std.testing.expect(buf.get(2, 0).eql(.{}));
}

test "editor: the window scrolls at the right edge and reports scroll_col" {
    var ed = try Editor.init(test_alloc, .{ .blink_ns = 0 });
    defer ed.deinit();
    try ed.insert("abcdefghij"); // 10 columns

    var buf = try Buffer.init(test_alloc, 6, 1);
    defer buf.deinit();

    // Cursor at the end: the window shows the tail and the cursor block.
    var consumed = try ed.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(usize, 5), ed.scroll_col);
    try std.testing.expectEqual(@as(u16, 6), consumed);
    var row: [16]u8 = undefined;
    try std.testing.expectEqualStrings("fghij ", rowStr(&buf, 0, &row));
    try std.testing.expect(buf.get(5, 0).style.eql(ed.cursor_style));

    // Home: the window snaps back to the line start.
    ed.moveHome();
    buf.clear();
    consumed = try ed.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(usize, 0), ed.scroll_col);
    try std.testing.expectEqual(@as(u16, 6), consumed);
    try std.testing.expectEqualStrings("abcdef", rowStr(&buf, 0, &row));
    try std.testing.expect(buf.get(0, 0).style.eql(ed.cursor_style));
}

test "editor: the cursor never leaves the drawn window" {
    var ed = try Editor.init(test_alloc, .{ .blink_ns = 0 });
    defer ed.deinit();
    try ed.insert("abcdefghij");

    const viewport: usize = 4;
    var i: usize = 0;
    while (i <= 10) : (i += 1) {
        ed.scrollTo(viewport);
        const rel = ed.cursorCol() -| ed.scroll_col;
        try std.testing.expect(rel < viewport);
        ed.moveLeft();
    }
}

test "editor: draw clips at the buffer edge without splitting a wide glyph" {
    var ed = try Editor.init(test_alloc, .{ .blink_ns = 0 });
    defer ed.deinit();
    try ed.insert(zwj_family ++ "ab");
    ed.moveHome();

    // Two columns: the family occupies both, and the marker redraws the
    // same cluster in the cursor style, so both its cells carry it.
    var buf = try Buffer.init(test_alloc, 2, 1);
    defer buf.deinit();
    const consumed = try ed.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 2), consumed);
    try std.testing.expectEqualStrings(zwj_family, buf.get(0, 0).grapheme);
    try std.testing.expect(buf.get(1, 0).wide);
    try std.testing.expect(buf.get(0, 0).style.eql(ed.cursor_style));
    try std.testing.expect(buf.get(1, 0).style.eql(ed.cursor_style));

    // One column: a 2-wide glyph cannot start there; nothing is drawn,
    // and no half cluster by either the window or the marker.
    var narrow = try Buffer.init(test_alloc, 1, 1);
    defer narrow.deinit();
    const narrow_consumed = try ed.draw(&narrow, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 0), narrow_consumed);
    try std.testing.expect(narrow.get(0, 0).eql(.{}));
}

test "editor: draw and motion never allocate" {
    var failing = std.testing.FailingAllocator.init(test_alloc, .{});
    var ed = try Editor.init(test_alloc, .{ .initial_capacity = 64 });
    defer ed.deinit();
    try ed.insert("some text to draw");
    // Grow the line far past its initial capacity: `draw` reads the line
    // directly, so no reservation made on the edit path can size the
    // window it paints.
    try ed.insert("x" ** 200);
    const real = ed.gpa;

    // From here on every allocation fails, so anything that reaches `gpa`
    // aborts the test.
    failing.fail_index = failing.alloc_index;
    ed.gpa = failing.allocator();

    var buf = try Buffer.init(test_alloc, 40, 1);
    defer buf.deinit();
    _ = try ed.draw(&buf, 0, 0, .fromNanoseconds(0));
    var row: [64]u8 = undefined;
    try std.testing.expectEqualStrings("x" ** 39 ++ " ", rowStr(&buf, 0, &row));
    try std.testing.expect(!ed.advance(.fromNanoseconds(0)));
    ed.moveHome();
    ed.moveWordRight();
    ed.moveWordLeft();
    ed.moveEnd();
    ed.moveLeft();
    ed.scrollTo(4);
    try std.testing.expectEqual(@as(usize, 217), ed.textWidth());
    _ = ed.cursorCol();
    _ = ed.text();

    ed.gpa = real;
}

test "editor: edits with undo disabled and capacity reserved never allocate" {
    var failing = std.testing.FailingAllocator.init(test_alloc, .{});
    var ed = try Editor.init(test_alloc, .{ .initial_capacity = 64, .undo_depth = 0 });
    defer ed.deinit();
    const real = ed.gpa;

    // The line has room and there is no snapshot to take: every edit below
    // must run without touching the allocator.
    failing.fail_index = failing.alloc_index;
    ed.gpa = failing.allocator();

    try ed.insert("mixed \u{e9}\u{1f600} text");
    try ed.backspace();
    try ed.deleteForward();
    ed.moveHome();
    try ed.deleteForward();
    try ed.insert("x");

    ed.gpa = real;
    try std.testing.expectEqualStrings("xixed \u{e9}\u{1f600} tex", ed.text());
}

test "editor: key maps only the editor's bindings" {
    var ed = try Editor.init(test_alloc, .{});
    defer ed.deinit();
    try ed.insert("one two");
    ed.moveEnd();

    // Unconsumed: submit, completion, escape, vertical keys and non-key events.
    try std.testing.expect(!try ed.key(press(Key.enter)));
    try std.testing.expect(!try ed.key(press(Key.tab)));
    try std.testing.expect(!try ed.key(press(Key.escape)));
    try std.testing.expect(!try ed.key(press(Key.up)));
    try std.testing.expect(!try ed.key(press(Key.down)));
    try std.testing.expect(!try ed.key(press(Key.left_control)));
    try std.testing.expect(!try ed.key(.focus_in));
    try std.testing.expectEqualStrings("one two", ed.text());

    // Consumed: word motion by arrow+modifier, by ctrl letter and by alt letter.
    try std.testing.expect(try ed.key(pressMod(Key.left, .{ .ctrl = true })));
    try std.testing.expectEqual(@as(usize, 4), ed.cursor);
    try std.testing.expect(try ed.key(pressMod(Key.left, .{ .alt = true })));
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
    try std.testing.expect(try ed.key(pressMod('f', .{ .ctrl = true })));
    try std.testing.expectEqual(@as(usize, 1), ed.cursor);
    try std.testing.expect(try ed.key(pressMod('f', .{ .alt = true })));
    try std.testing.expectEqual(@as(usize, 3), ed.cursor);
    try std.testing.expect(try ed.key(press(Key.end)));
    try std.testing.expectEqual(@as(usize, 7), ed.cursor);

    // Kills, yank and undo through the key path.
    try std.testing.expect(try ed.key(pressMod('w', .{ .ctrl = true })));
    try std.testing.expectEqualStrings("one ", ed.text());
    try std.testing.expect(try ed.key(pressMod('y', .{ .ctrl = true })));
    try std.testing.expectEqualStrings("one two", ed.text());
    // One ring entry: the binding is consumed, but there is nothing to cycle.
    try std.testing.expect(try ed.key(pressMod('y', .{ .alt = true })));
    try std.testing.expectEqualStrings("one two", ed.text());
    try std.testing.expect(try ed.key(pressMod('z', .{ .ctrl = true })));
    try std.testing.expectEqualStrings("one ", ed.text());
    // ctrl-underscore (the 0x1F ground-state byte) is the same binding:
    // each undo step is one destructive operation.
    try std.testing.expect(try ed.key(press(0x1F)));
    try std.testing.expectEqualStrings("one two", ed.text());
    try std.testing.expect(try ed.key(pressMod('z', .{ .ctrl = true })));
    try std.testing.expectEqualStrings("", ed.text());
}

test "editor: ctrl-d at the line end is left to the caller" {
    var ed = try Editor.init(test_alloc, .{});
    defer ed.deinit();
    try ed.insert("ab");

    try std.testing.expect(!try ed.key(pressMod('d', .{ .ctrl = true })));
    try std.testing.expect(!try ed.key(press(Key.delete)));
    try std.testing.expectEqualStrings("ab", ed.text());

    ed.moveHome();
    try std.testing.expect(try ed.key(pressMod('d', .{ .ctrl = true })));
    try std.testing.expectEqualStrings("b", ed.text());
    try std.testing.expect(try ed.key(press(Key.delete)));
    try std.testing.expectEqualStrings("", ed.text());
}

test "editor: a paste event inserts and multi-byte key text lands verbatim" {
    var ed = try Editor.init(test_alloc, .{});
    defer ed.deinit();

    try std.testing.expect(try ed.key(.{ .paste = "pasted \u{e9}" }));
    try std.testing.expectEqualStrings("pasted \u{e9}", ed.text());

    try std.testing.expect(try ed.key(pressText('\u{1f600}', "\u{1f600}")));
    try std.testing.expectEqualStrings("pasted \u{e9}\u{1f600}", ed.text());

    // A key event whose text is empty (an unmapped control key) is not text.
    try std.testing.expect(!try ed.key(pressText('\u{1}', "")));
    try std.testing.expectEqualStrings("pasted \u{e9}\u{1f600}", ed.text());
}

test "editor: a wide cursor marker paints both of its columns" {
    var ed = try Editor.init(test_alloc, .{ .blink_ns = 0 });
    defer ed.deinit();
    try ed.insert("\u{1f600}x");
    ed.moveHome();

    var buf = try Buffer.init(test_alloc, 4, 1);
    defer buf.deinit();
    const consumed = try ed.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 3), consumed);

    // The marker covers both columns of the emoji as one lead plus its
    // continuation — not two painted glyphs — while "x" keeps the line
    // style.
    try std.testing.expectEqualStrings("\u{1f600}", buf.get(0, 0).grapheme);
    try std.testing.expect(buf.get(0, 0).style.eql(ed.cursor_style));
    try std.testing.expect(buf.get(1, 0).wide);
    try std.testing.expect(buf.get(1, 0).style.eql(ed.cursor_style));
    try std.testing.expectEqualStrings("x", buf.get(2, 0).grapheme);
    try std.testing.expect(!buf.get(2, 0).style.eql(ed.cursor_style));
}

/// Fixed-buffer writer for the terminal-output regression tests (same
/// pattern as src/buffer.zig).
const TestWriter = struct {
    buf: [1024]u8 = undefined,
    w: std.Io.Writer = undefined,

    fn init(self: *TestWriter) void {
        self.w = .fixed(&self.buf);
    }
};

test "editor: a scrolled wide cluster does not hide the character before the cursor" {
    var ed = try Editor.init(test_alloc, .{ .blink_ns = 0 });
    defer ed.deinit();
    try ed.insert("a界b");

    var buf = try Buffer.init(test_alloc, 3, 1);
    defer buf.deinit();
    _ = try ed.draw(&buf, 0, 0, .fromNanoseconds(0));

    var row: [32]u8 = undefined;
    try std.testing.expectEqualStrings("b  ", rowStr(&buf, 0, &row));
    try std.testing.expect(buf.get(1, 0).style.eql(ed.cursor_style));
    try std.testing.expectEqual(@as(usize, 3), ed.scroll_col);

    ed.moveLeft();
    buf.clear();
    _ = try ed.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqualStrings("b  ", rowStr(&buf, 0, &row));
    try std.testing.expect(buf.get(0, 0).style.eql(ed.cursor_style));

    ed.moveHome();
    buf.clear();
    _ = try ed.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqualStrings("a界", rowStr(&buf, 0, &row));
    try std.testing.expect(buf.get(0, 0).style.eql(ed.cursor_style));
}

/// The cluster the cursor sits on: the one starting at the cursor, or the
/// empty slice at the end of the line.
fn cursorCluster(ed: *const Editor) []const u8 {
    const tail = ed.text()[ed.cursorAt()..];
    return tail[0..Width.firstCellLen(tail)];
}

/// Every cell the window owns is intact: a wide lead keeps its
/// continuation column, a continuation keeps its lead, and no column left
/// of the cursor is blank. A blank there is text the frame lost or painted
/// over — what a window that starts mid-cluster does to the wide cluster
/// it cut in half.
fn expectIntactRow(buf: *const Buffer, rel: usize) !void {
    const width: usize = buf.width;
    var x: usize = 0;
    while (x < width) : (x += 1) {
        const cell = buf.get(@intCast(x), 0);
        if (cell.wide) {
            try std.testing.expect(x > 0);
            const lead = buf.get(@intCast(x - 1), 0);
            try std.testing.expect(lead.grapheme.len > 0 and
                Width.graphemeWidth(lead.grapheme) >= 2);
        } else if (cell.grapheme.len > 0 and Width.graphemeWidth(cell.grapheme) >= 2) {
            try std.testing.expect(x + 1 < width);
            try std.testing.expect(buf.get(@intCast(x + 1), 0).wide);
        }
        if (x < rel) try std.testing.expect(cell.wide or cell.grapheme.len > 0);
    }
}

test "editor: every window width keeps the cursor cell and the text before it" {
    // Columns: "a" 0, 界 1-2, "e"+acute 3, the ZWJ family 4-5, "b" 6.
    var ed = try Editor.init(test_alloc, .{ .blink_ns = 0 });
    defer ed.deinit();
    try ed.insert("a界" ++ e_acute ++ zwj_family ++ "b");

    var viewport: usize = 1;
    while (viewport <= 6) : (viewport += 1) {
        var buf = try Buffer.init(test_alloc, @intCast(viewport), 1);
        defer buf.deinit();

        // Five clusters, so six cursor stops: on every boundary and past
        // the last one. The window carries over between frames, so each
        // width also follows the one before it.
        var stop: usize = 0;
        while (stop <= 5) : (stop += 1) {
            ed.moveHome();
            for (0..stop) |_| ed.moveRight();

            buf.clear();
            _ = try ed.draw(&buf, 0, 0, .fromNanoseconds(0));

            const rel = ed.cursorCol() - ed.scroll_col;
            try std.testing.expect(rel < viewport);
            try expectIntactRow(&buf, rel);

            // The marker sits on the cursor's own cluster, or the row stops
            // short of a glyph the window's last column cannot hold.
            const under = cursorCluster(&ed);
            const uw: usize =
                if (under.len == 0) 1 else @as(usize, @intCast(Width.graphemeWidth(under)));
            if (rel + uw <= viewport) {
                try std.testing.expectEqualStrings(
                    if (under.len > 0) under else " ",
                    buf.get(@intCast(rel), 0).grapheme,
                );
                try std.testing.expect(buf.get(@intCast(rel), 0).style.eql(ed.cursor_style));
            } else {
                var x = rel;
                while (x < viewport) : (x += 1) {
                    try std.testing.expect(buf.get(@intCast(x), 0).eql(.{}));
                }
            }
        }
    }
}

test "editor: the window and the marker are anchored at the draw x" {
    // Columns: "a" 0, 界 1-2, "b" 3, 界 4-5, "c" 6.
    var ed = try Editor.init(test_alloc, .{ .blink_ns = 0 });
    defer ed.deinit();
    try ed.insert("a界b界c");

    var buf = try Buffer.init(test_alloc, 9, 1);
    defer buf.deinit();
    const x: u16 = 3; // six columns left to the right of x

    // The window is sized off what is left of the row, not off the whole
    // row: six columns put the edge on 3 (past the wide cluster that
    // straddles 2) and the end-of-line marker lands inside the buffer. A
    // window sized off `buf.width` would start at "a" and push the marker
    // off the row.
    const consumed = try ed.draw(&buf, x, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 5), consumed);
    try std.testing.expectEqual(@as(usize, 3), ed.scroll_col);
    try std.testing.expectEqualStrings("b", buf.get(x, 0).grapheme);
    try std.testing.expectEqualStrings("界", buf.get(x + 1, 0).grapheme);
    try std.testing.expect(buf.get(x + 2, 0).wide);
    try std.testing.expectEqualStrings("c", buf.get(x + 3, 0).grapheme);
    try std.testing.expect(buf.get(x + 4, 0).style.eql(ed.cursor_style));
    try std.testing.expect(buf.get(x + 5, 0).eql(.{}));
    // Nothing left of x was touched.
    try std.testing.expect(buf.get(0, 0).eql(.{}));
    try std.testing.expect(buf.get(2, 0).eql(.{}));
}

test "editor: a hidden blink phase repaints a wide cursor cluster whole" {
    var ed = try Editor.init(test_alloc, .{ .blink_ns = 100 });
    defer ed.deinit();
    try ed.insert("a界b");
    ed.moveHome();
    ed.moveRight(); // the cursor sits on the wide cluster at columns 1-2

    var buf = try Buffer.init(test_alloc, 4, 1);
    defer buf.deinit();

    _ = try ed.draw(&buf, 0, 0, .fromNanoseconds(0)); // visible
    try std.testing.expectEqualStrings("界", buf.get(1, 0).grapheme);
    try std.testing.expect(buf.get(1, 0).style.eql(ed.cursor_style));
    try std.testing.expect(buf.get(2, 0).style.eql(ed.cursor_style));

    // Hidden: both columns go back to the line style over the previous
    // frame, so a diffed buffer keeps neither half of the highlight and
    // the lead is not left without its continuation.
    _ = try ed.draw(&buf, 0, 0, .fromNanoseconds(100));
    try std.testing.expectEqualStrings("界", buf.get(1, 0).grapheme);
    try std.testing.expect(buf.get(2, 0).wide);
    try std.testing.expect(buf.get(1, 0).style.eql(ed.style));
    try std.testing.expect(buf.get(2, 0).style.eql(ed.style));

    // Visible again: the marker takes both columns back.
    _ = try ed.draw(&buf, 0, 0, .fromNanoseconds(200));
    try std.testing.expect(buf.get(1, 0).style.eql(ed.cursor_style));
    try std.testing.expect(buf.get(2, 0).style.eql(ed.cursor_style));
    try expectIntactRow(&buf, 1);
}

test "editor: the window follows a shrinking and re-expanding viewport" {
    var ed = try Editor.init(test_alloc, .{ .blink_ns = 0 });
    defer ed.deinit();
    try ed.insert("a界b界c"); // 7 columns, the cursor at the end

    var row: [32]u8 = undefined;
    var buf = try Buffer.init(test_alloc, 8, 1);
    defer buf.deinit();
    _ = try ed.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqualStrings("a界b界c ", rowStr(&buf, 0, &row));
    try std.testing.expect(buf.get(7, 0).style.eql(ed.cursor_style));

    // Three columns: the edge would land inside the wide cluster at 4-5,
    // which is drawn whole to the left of the window rather than half in
    // it, and the cursor keeps its cell.
    try buf.resize(3, 1);
    _ = try ed.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(usize, 6), ed.scroll_col);
    try std.testing.expectEqualStrings("c", buf.get(0, 0).grapheme);
    try std.testing.expect(buf.get(1, 0).style.eql(ed.cursor_style));
    try std.testing.expect(buf.get(2, 0).eql(.{}));

    // Wide again: the line head is not lost — the window returns to the
    // start and the marker moves back with it.
    try buf.resize(8, 1);
    _ = try ed.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(usize, 0), ed.scroll_col);
    try std.testing.expectEqualStrings("a界b界c ", rowStr(&buf, 0, &row));
    try std.testing.expect(buf.get(7, 0).style.eql(ed.cursor_style));
}
