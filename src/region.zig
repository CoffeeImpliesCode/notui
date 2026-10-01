//! Region: the inline renderer — the v0 centerpiece.
//!
//! A `Region` owns a fixed `height`-row band in the terminal's main
//! buffer (never the alt screen) and repaints it in place, writes
//! scrollback ABOVE the band through a receipt-tracked ledger, anchors
//! the cursor relative to the band top, and leaves the final frame in
//! the transcript on exit.
//!
//! Mechanics
//! ---------
//!
//! - **Paint envelope (B2).** Every interactive frame is staged as one
//!   contiguous run of bytes — sync start (when the terminal supports
//!   DEC 2026) → hide cursor (on the visible→hidden transition) →
//!   autowrap off (DECAWM) → frame → autowrap on → sync end → show
//!   cursor (on the hidden→visible transition). `interactive` gates the
//!   whole envelope; `sync_output` only gates the 2026 pair. A frame
//!   that changes nothing emits ZERO bytes, envelope included.
//!   `exit()` (and the panic path in tty.zig) restores autowrap, the
//!   cursor and the sync state.
//!
//! - **Transactional frames.** `render` stages the whole frame into the
//!   writer and commits the region state — `prev`, the dirty flags, the
//!   append queue, the ledger receipts, the anchor — only after the last
//!   byte is staged. A writer that fails (a full output queue, B1)
//!   therefore leaves the region exactly as it was, and the caller can
//!   retry the same frame later.
//!
//! - **Anchor.** The band top is the anchor; between frames the cursor
//!   sits at the band bottom (column 1 of the last row) and every move
//!   is relative (`\r` + CUU / CNL / ED). No absolute CUP is emitted
//!   except `placeAt`, which restores the parked cursor. `anchor_row`
//!   is bookkeeping only; CPR (`ESC[6n`) re-anchors it on the first
//!   render, after a resize, when a released band comes back, after a
//!   text-ledger flush, and on `reanchor()`.
//!
//! - **Erase discipline (B3).** No screen-wide erase: the renderer
//!   never emits ED2 (`ESC[2J`) or ED3 (`ESC[3J`), so tmux and
//!   conhost scrollback above the band is never destroyed. Every erase
//!   is either row-scoped (EL, `ESC[K`) or ED0 (`ESC[J`) from the band
//!   anchor downward — the rows the band owns and nothing above it.
//!   Committed history is never erased. Strategy-by-strategy bytes:
//!   `first` (no erase), `ledger` (ED0 at the anchor), `resize` (ED0 at
//!   the anchor in `append`, per-row EL in `rebuild` and `preserve`),
//!   `grow` (no erase, CNL reservation),
//!   `shrink` (per-row EL), `diff` (per-row EL for the
//!   high-water tail), `collapse` (no erase — the band is released, not
//!   erased). The band extent the CURRENT frame settles — the painted
//!   one for a steady diff, the reserved or kept one for a height
//!   change — drives every cursor move; never a `new - old` delta and
//!   never the extent the previous frame left behind.
//!
//! - **Ledger (C1).** `writeHistory` takes a `HistoryBatch` with a
//!   monotonic `id`, caller-owned `rows` and a `kind`
//!   (`.append` writes rows above the band; `.replay` rewrites the
//!   complete logical ledger in one atomic write and supersedes every
//!   other batch staged but unwritten, plus the queued appends). A
//!   replay's supersession is a COMMIT-time effect: its bytes reach the
//!   wire before anything is discarded, so a frame that dies on a full
//!   output queue (B1) keeps every unwritten batch and every queued
//!   append for the exact retry, and a written batch is never
//!   discarded. The rows are COPIED into
//!   Region-owned staging and retained until they are acknowledged:
//!   `acknowledgeHistory` (product ack) and `acknowledgeDrained`
//!   (transport ack). Acknowledgement never runs ahead of the write —
//!   only a batch whose bytes were staged may be acknowledged, and the
//!   released batch is always the acknowledged head, so the written
//!   range stays a prefix and no unwritten row is ever released. Ids
//!   are monotonic and written exactly once — a duplicate pending or
//!   already-written id is `error.DuplicateHistoryId`, never a second
//!   append. The renderer never probes the terminal's scroll position.
//!
//! - **Resize modes (C2).** `Options.resize_mode` decides what a width
//!   change does to the rows the band still paints: `.append` erases
//!   from the anchor and repaints the band in place; `.rebuild`
//!   re-anchors at the live bottom and repaints downward, so the band
//!   top moves to the old bottom and the anchor follows it (the CPR
//!   reply confirms the new top); `.preserve` reflows the
//!   settled rows the app re-lays out, painting row-scoped (no ED0) so
//!   nothing above the band moves. In every mode the transcript above
//!   the band keeps its rows: a resize never rewrites committed
//!   history. `painted_rows` still drives every cursor move in these
//!   modes: the band keeps the extent it physically occupies.
//!
//! Writer-agnostic: imports only buffer, cell, style, emit, image
//! (kitty placement via `placeAt`), width and caps. No tty, no zg — the
//! zg import grep-gate is `width.zig` only.

const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Cell = @import("cell.zig").Cell;
const Style = @import("style.zig").Style;
const emit = @import("emit.zig");
const Width = @import("width.zig");
const caps = @import("caps.zig");
const image = @import("image.zig"); // no cycle — image.zig imports only std

/// One ledger write (roadmap C1, zomp's history contract).
///
/// `id` is monotonic per session: the Region writes each id exactly
/// once and rejects a duplicate. `rows` are caller-owned at the call
/// boundary — the Region copies them and retains the copy until the
/// transport acknowledged the batch, so the caller may reuse its
/// staging memory as soon as `writeHistory` returns.
pub const HistoryBatch = struct {
    /// Monotonic batch id (0 is reserved: it is never a valid id).
    id: u64,
    /// Exact terminal rows; each occupies one row, no terminal wrap.
    rows: []const []const u8,
    kind: enum {
        /// Rows appended above the band, in scrollback.
        append,
        /// The complete logical ledger, rewritten atomically. Anything
        /// staged but unwritten, and every queued append, is
        /// superseded — dropped only once the replay's bytes are
        /// staged, so a frame that dies part-way still owns the whole
        /// queue for the retry.
        replay,
    },
};

/// What a width change does to the rows the band still paints (C2).
pub const ResizeMode = enum {
    /// Erase from the band anchor (ED0) and repaint the band in place.
    /// The anchor never moves; the band keeps its place on screen.
    append,
    /// Re-anchor at the live band bottom and repaint downward, so a
    /// shortened band leaves the remaining rows on screen as settled
    /// content. The band top moves to where the old bottom was, so the
    /// next frame's relative moves start from the row this one parked
    /// on — never one below it.
    rebuild,
    /// Reflow the settled rows the app re-lays out for the new width,
    /// painting row-scoped (no ED0). Nothing above the band moves.
    preserve,
};

/// The inline Region renderer.
pub const Region = struct {
    pub const Options = struct {
        /// Number of terminal rows the region owns.
        height: u16,
        /// Reserve the band on the FIRST render with `ESC[n E` (CNL),
        /// pushing the terminal so the region owns a stable band. Later
        /// height changes always reserve physically (a band that does
        /// not exist cannot be painted).
        append_lines: bool = true,
        /// Interactive terminal session: the paint envelope, cursor
        /// hiding, CPR re-queries, band reservation, the ledger and the
        /// exit park. False = piped/degraded output: one plain frame,
        /// no escape sequences, and `sync_output` is ignored.
        interactive: bool = true,
        /// The terminal answered DECRQM for synchronized output (mode
        /// 2026). Gates only the sync pair inside the envelope; it is
        /// NOT the interactive flag (that conflation was the bug this
        /// split removes — see PORTING.md).
        sync_output: bool = true,
        /// Width measurement policy; passed through to the width seam
        /// consumers (Buffer.draw enforces width via zg).
        width_policy: caps.Capabilities.WidthPolicy = .zg_unicode,
        /// Resize behaviour for a width change.
        resize_mode: ResizeMode = .append,
        /// Hard bound on retained ledger bytes (copied rows waiting for
        /// a receipt). Exceeding it is `error.HistoryTooLarge`, never a
        /// silent drop.
        max_history_bytes: usize = 256 * 1024,
    };

    /// Queued output written ABOVE the region into scrollback before the
    /// next render (the print-above escape hatch).
    pub const Append = union(enum) {
        /// Free text; the terminal reflows/wraps it. Internal `\n` is
        /// written as `\r\n`. The row count is terminal-decided, so the
        /// anchor is re-queried next frame.
        text: []const u8,
        /// One hard-wrapped exact-layout terminal row. Written verbatim,
        /// occupies exactly one row — the anchor shifts deterministically.
        line: []const u8,
    };

    /// What a frame does with the band. Every strategy is a total
    /// function of the frame's inputs; see the erase matrix in the
    /// module docs (B3).
    const Strategy = enum {
        /// Reserve and append `height` rows without clearing.
        first,
        /// Write queued appends/ledger rows above the band, then repaint.
        ledger,
        /// A width change (mode-dependent repaint).
        resize,
        /// The band grew: reserve the new rows, diff them.
        grow,
        /// The band shrank: erase the removed tail row-scoped, diff.
        shrink,
        /// `height` reached 0: release the band, erase nothing.
        collapse,
        /// Steady state: diff, then clear the high-water tail.
        diff,
    };
    /// The state one frame intends to change. Nothing here is applied
    /// until the frame is fully staged (transactional frames).
    const Frame = struct {
        /// Envelope + CPR.
        cpr: bool = false,
        hide_cursor: bool = false,
        show_cursor: bool = false,
        /// Bookkeeping the frame applies on commit.
        anchor_add: u16 = 0,
        high_water: u16 = 0,
        painted: u16 = 0,
        anchor_dirty: bool = false,
        clear_first: bool = false,
        clear_width_dirty: bool = false,
        clear_height_dirty: bool = false,
        /// The band was released by this frame; publishes `collapsed`.
        release: bool = false,
        /// The append queue left this frame in whatever state the
        /// frame wrote it: unchanged (nothing to write), emptied
        /// (written out), or superseded by a `replay`.
        took_appends: bool = false,
        /// The write cursor advances to the end of the retained list.
        took_history: bool = false,
        /// A `.replay` batch's rows were staged. At commit the replay
        /// stands alone in the written range: every other unwritten
        /// batch is released and the queued appends are dropped. Until
        /// then the ledger is untouched, so a frame that dies part-way
        /// through the replay bytes keeps the whole batch list.
        replay: ?usize = null,
    };

    pub const WriteHistoryError = error{ DuplicateHistoryId, HistoryTooLarge, OutOfMemory };
    pub const AcknowledgeError = error{UnknownHistoryId};

    gpa: std.mem.Allocator,
    /// Current frame the app draws into; public so apps can draw.
    cur: Buffer,
    /// Previous frame, diffed against on `.diff` frames.
    prev: Buffer,
    /// Immutable snapshot of the previous frame's cell text.
    ///
    /// `prev` must NOT borrow the app's staging memory: an app that
    /// mutates its own bytes in place — a counter, a percentage, an
    /// editor line, all rewritten at the same length — would change
    /// `prev` too, and the damage test would call the row unchanged and
    /// repaint nothing. A committed frame therefore copies its cell text
    /// into this arena and points `prev` at the copies.
    prev_text: std.heap.ArenaAllocator,
    /// The arena the NEXT snapshot is built in. Kept separate so a
    /// failed prepare leaves the live snapshot intact: the two swap only
    /// after a complete snapshot exists.
    snapshot_scratch: std.heap.ArenaAllocator,
    /// The per-cell owned slices of the prepared snapshot, in cell order.
    /// Reused across frames with its capacity retained, so a steady
    /// session allocates nothing per frame.
    snapshot_cells: std.ArrayListUnmanaged([]const u8) = .empty,
    opts: Options,

    /// Tracked terminal row of the band top (1-indexed, DEC CPR
    /// convention; shifted by ledger writes). Bookkeeping only, exposed
    /// through `anchorRow` for absolute-row placement (kitty graphics).
    anchor_row: u16 = 0,
    /// Highest row index ever painted; the shrink path erases stale rows
    /// between the content end and this mark.
    high_water: u16 = 0,
    /// Terminal rows the band PHYSICALLY occupies right now. Not the
    /// same as `height` after a collapse or before a reserve ran; every
    /// cursor move uses this, never `new - old`.
    painted_rows: u16 = 0,
    /// A CPR re-query is due at the next render start.
    anchor_dirty: bool = true,
    /// A width change / forced full redraw is due.
    width_dirty: bool = false,
    /// A height-only change is pending.
    height_dirty: bool = false,
    /// Rows added by the last height change (0 unless growing).
    grow_rows: u16 = 0,
    /// Rows removed by the last height change (0 unless shrinking).
    shrink_rows: u16 = 0,
    /// The region has not rendered yet (strategy `first` pending).
    first_frame: bool = true,
    /// The band is released (`height == 0` and nothing is painted).
    collapsed: bool = false,
    /// A `collapse` released the band and nothing has re-created it
    /// since. The cursor then sits on settled content, so the next
    /// reservation is physical whatever `Options.append_lines` says.
    released: bool = false,
    /// The terminal cursor is hidden by this region.
    cursor_hidden: bool = false,
    /// The desired cursor state; the envelope restores it every frame.
    cursor_wanted_hidden: bool = true,
    /// `exit()` already ran (idempotence).
    exited: bool = false,
    /// Pending appends, flushed before the region renders each frame.
    append_queue: std.ArrayListUnmanaged(Append) = .empty,
    /// The width the band is currently painted at (`.preserve` reflow).
    last_width: u16 = 80,
    /// Retained ledger batches, in write order. The first
    /// `history_written` are staged into the byte stream; the rest are
    /// still unwritten. Everything here is released on acknowledgement.
    history: std.ArrayListUnmanaged(OwnedBatch) = .empty,
    history_written: usize = 0,
    history_bytes: usize = 0,
    /// Highest batch id accepted.
    history_high: u64 = 0,
    /// Receipts of the batches a transport drained (`.acknowledgeDrained`).
    history_ids: std.ArrayListUnmanaged(u64) = .empty,
    /// Scratch for `historyPending` (no allocation in steady state).
    history_pending_buf: std.ArrayListUnmanaged(u64) = .empty,

    /// Buffer width (mirrors `cur.width`; default 80 until the app
    /// resizes from the terminal winsize).
    width: u16,
    /// Buffer height (mirrors `cur.height`; from `opts.height`).
    height: u16,

    const OwnedBatch = struct {
        id: u64,
        kind: @FieldType(HistoryBatch, "kind"),
        /// Owned row copies, in order.
        rows: [][]u8,
        bytes: usize,
        acked: bool = false,
    };

    /// Allocate the double buffer and the ledger state.
    ///
    /// Buffers start 80 columns wide — a zero-width buffer would
    /// silently drop the first frame's draws until a resize arrives.
    pub fn init(gpa: std.mem.Allocator, opts: Options) !Region {
        var cur = try Buffer.init(gpa, 80, opts.height);
        errdefer cur.deinit();
        var prev = try Buffer.init(gpa, 80, opts.height);
        errdefer prev.deinit();
        return .{
            .gpa = gpa,
            .cur = cur,
            .prev = prev,
            .prev_text = std.heap.ArenaAllocator.init(gpa),
            .snapshot_scratch = std.heap.ArenaAllocator.init(gpa),
            .opts = opts,
            .height = opts.height,
            .width = 80,
            .last_width = 80,
            .collapsed = opts.height == 0,
        };
    }

    pub fn deinit(self: *Region) void {
        for (self.history.items) |b| self.releaseBatch(b);
        self.history.deinit(self.gpa);
        self.history_ids.deinit(self.gpa);
        self.history_pending_buf.deinit(self.gpa);
        self.snapshot_cells.deinit(self.gpa);
        self.snapshot_scratch.deinit();
        self.prev_text.deinit();
        self.append_queue.deinit(self.gpa);
        self.cur.deinit();
        self.prev.deinit();
        self.* = undefined;
    }

    /// Reallocate both buffers (overlap copied by `Buffer.resize`),
    /// mark the next frame for a resize repaint and a CPR re-query.
    /// A pure height change routes to `setHeight` (no width repaint).
    pub fn resize(self: *Region, new_width: u16, new_height: u16) !void {
        if (new_width == self.width) return self.setHeight(new_height);
        const old_height = self.height;
        try self.cur.resize(new_width, new_height);
        try self.prev.resize(new_width, new_height);
        self.width = new_width;
        self.height = new_height;
        self.width_dirty = true;
        self.anchor_dirty = true;
        if (old_height == 0 and new_height > 0) {
            // The band was released: the next frame reserves and appends
            // it again (there is nothing on screen to repaint in place),
            // and re-queries where that new band starts.
            self.first_frame = true;
            self.collapsed = false;
            self.anchor_dirty = true;
        } else if (new_height == 0) {
            self.collapsed = true;
        }
    }

    /// Height-only resize. Reallocates both buffers to `new_height`
    /// keeping the width and marks the next frame for the `grow`,
    /// `shrink` or `collapse` strategy.
    ///
    /// Growth always reserves the new rows with CNL: without a physical
    /// reservation the band would not exist on screen and the diff
    /// would paint rows that are not there. `Options.append_lines`
    /// governs only the FIRST-frame reservation. Shrink erases the
    /// removed tail row-scoped (EL) and never touches committed history.
    /// `new_height == 0` releases the band (`.collapse`): the rows stay
    /// on screen as settled content and the next non-zero height
    /// re-reserves from the cursor. No-op when unchanged.
    pub fn setHeight(self: *Region, new_height: u16) !void {
        const old_height = self.height;
        if (new_height == old_height) return;
        try self.cur.resize(self.width, new_height);
        try self.prev.resize(self.width, new_height);
        self.height = new_height;
        self.height_dirty = true;
        self.grow_rows = if (new_height > old_height) new_height - old_height else 0;
        self.shrink_rows = if (new_height < old_height) old_height - new_height else 0;
        if (old_height == 0 and new_height > 0) {
            // Released band: re-reserve from the cursor and re-query the
            // row the new band starts on.
            self.first_frame = true;
            self.collapsed = false;
            self.anchor_dirty = true;
        }
        if (new_height == 0) {
            self.collapsed = true;
        }
    }

    /// Queue `item` to flush ABOVE the region on the next render.
    pub fn append(self: *Region, item: Append) !void {
        try self.append_queue.append(self.gpa, item);
    }

    /// Force a full redraw on the next render.
    pub fn renderFull(self: *Region, w: anytype) !void {
        self.width_dirty = true;
        try self.render(w);
    }

    /// Mark the anchor as suspect; the next render re-queries CPR (the
    /// reply surfaces as `Event.cpr` for the app — see `applyCpr`).
    pub fn reanchor(self: *Region) !void {
        self.anchor_dirty = true;
    }

    /// The desired cursor state for the paint envelope. The envelope
    /// hides the cursor when the app wants it hidden and shows it again
    /// on the frame that switches the desire (B2).
    pub fn setCursorHidden(self: *Region, hidden: bool) void {
        self.cursor_wanted_hidden = hidden;
    }

    /// Apply a Cursor Position Report (CPR) reply, correcting
    /// `anchor_row` from the terminal's answer to the last
    /// `queryCursor`. Between frames the cursor sits at the band bottom
    /// (column 1 of the last row), so the reply's 1-indexed row IS that
    /// bottom row and the band top is `height - 1` rows above it:
    /// `anchor_row = row -| (height - 1)`, clamped to 0. `col` is
    /// ignored: the parking is always column 1.
    ///
    /// The reply is asynchronous — if it lands while a frame is
    /// mid-render it describes the pre-render cursor, so the correction
    /// applies at the next frame. Painting is cursor-relative, so the
    /// next render's diff repaints at the corrected rows with no forced
    /// redraw. Clears `anchor_dirty` (the query was answered).
    pub fn applyCpr(self: *Region, row: u16, col: u16) !void {
        _ = col;
        self.anchor_row = row -| (self.painted_rows -| 1);
        self.anchor_dirty = false;
    }

    /// The tracked absolute terminal row of the band top (1-indexed; 0
    /// until the first CPR reply anchors it). Apps place absolute-row
    /// content — kitty graphics — at `anchorRow() + <band row>`.
    pub fn anchorRow(self: *const Region) u16 {
        return self.anchor_row;
    }

    /// FIRST CPR reply handling: re-anchors exactly from the tracked
    /// shifts. The first query fires at the first render's start,
    /// BEFORE the `first` strategy ran — the reply's 1-indexed row is
    /// the pre-frame cursor row R, and the bookkeeping has absorbed
    /// every shift applied on top of R (a CNL reservation, a ledger
    /// write, a physical height change), so `anchor_row +|= R` lands on
    /// the real band top.
    pub fn applyFirstCpr(self: *Region, row: u16) void {
        self.anchor_row +|= row;
    }

    /// Options for `placeAt` (the absolute row/col are derived from the
    /// region's anchor + the positional args).
    pub const PlaceAtOptions = struct {
        /// Cache id from a prior `transmit`.
        id: u32,
        /// Display size in CELLS (c/r span); null = native pixel size.
        size: ?image.kitty.CellSize = null,
        /// Placement id; re-placing the same (id, placement) moves the
        /// image without trails.
        placement: ?u32 = null,
        /// Stacking order; negative renders beneath text.
        z_index: ?i32 = null,
    };

    /// Place a kitty image at band row `band_row` (0-based within the
    /// band), column `col` (1-indexed), then restore the parked cursor.
    /// The cursor is moved to the absolute cell (anchor + band row) so
    /// the placement renders there, and CUP'd back to the band bottom
    /// (column 1 of the last row) so the next frame's relative moves
    /// start where the painter expects. The one absolute cursor
    /// positioning in this file (grep-gate exception; cursor restored).
    pub fn placeAt(
        self: *Region,
        w: anytype,
        band_row: u32,
        col: u32,
        opts: PlaceAtOptions,
    ) !void {
        const top: u32 = self.anchorRow();
        try image.kitty.place(w, .{
            .id = opts.id,
            .col = col,
            .row = top + band_row,
            .size = opts.size,
            .placement = opts.placement,
            .z_index = opts.z_index,
        });
        try w.print("\x1b[{d};1H", .{top + @as(u32, self.painted_rows -| 1)});
    }

    /// The width the band is currently painted at. A `.preserve` reflow
    /// compares it with `width` to know the layout the visible rows were
    /// composed at (C2).
    pub fn paintedWidth(self: *const Region) u16 {
        return self.last_width;
    }

    // ── ledger (C1) ─────────────────────────────────────

    /// Stage a ledger batch. The rows are copied into Region-owned
    /// memory bounded by `Options.max_history_bytes`; the caller keeps
    /// ownership of its slices.
    ///
    /// Ids are monotonic: a duplicate — still pending, already written,
    /// or already acknowledged — is `error.DuplicateHistoryId` and
    /// changes nothing. `error.HistoryTooLarge` when the retained bytes
    /// would exceed the bound; the batch is not staged, so nothing is
    /// ever dropped silently.
    pub fn writeHistory(self: *Region, batch: HistoryBatch) WriteHistoryError!void {
        if (batch.id == 0 or batch.id <= self.history_high) return error.DuplicateHistoryId;
        var total: usize = 0;
        for (batch.rows) |row| total += row.len + 1;
        if (self.history_bytes + total > self.opts.max_history_bytes) return error.HistoryTooLarge;

        // Reserve EVERY fallible allocation before any ownership moves:
        // once the copies exist nothing below can fail, so every error
        // path leaves the Region exactly as it found it — no leaked row
        // copies, no array the ledger still points at after a free.
        try self.history.ensureUnusedCapacity(self.gpa, 1);
        try self.history_ids.ensureTotalCapacity(self.gpa, self.history.items.len + 1);

        const rows = try self.gpa.alloc([]u8, batch.rows.len);
        var filled: usize = 0;
        errdefer {
            // `filled` counts the copies that exist; the rest of the
            // array was never written.
            for (rows[0..filled]) |copied| self.gpa.free(copied);
            self.gpa.free(rows);
        }
        while (filled < batch.rows.len) : (filled += 1) {
            rows[filled] = try self.gpa.dupe(u8, batch.rows[filled]);
        }

        self.history.appendAssumeCapacity(.{
            .id = batch.id,
            .kind = batch.kind,
            .rows = rows,
            .bytes = total,
        });
        self.history_bytes += total;
        self.history_high = batch.id;
    }

    /// Stage `rows` as one ledger batch with the next Region-owned
    /// monotonic id and return that id — the receipt to hand back to
    /// `acknowledgeHistory` (or to the transcript's `commitReceipt`)
    /// once the transport accepted it. The id is always fresh, so the
    /// failure a caller can hit is the retained-bytes bound.
    pub fn writeTranscript(self: *Region, rows: []const []const u8) WriteHistoryError!u64 {
        const id = self.history_high + 1;
        try self.writeHistory(.{ .id = id, .rows = rows, .kind = .append });
        return id;
    }

    /// Acknowledge that batch `id`'s bytes were written: the retained
    /// copy is released once the acknowledged prefix reaches it, and
    /// the id never returns.
    ///
    /// Only a WRITTEN batch may be acknowledged — an id still waiting for
    /// a frame is `error.UnknownHistoryId`, because acknowledging it
    /// would release rows the terminal has never seen (history written
    /// once, THEN acknowledged). Acknowledge out of write order is fine:
    /// only that batch disappears, and never before the batches in front
    /// of it, which is what keeps the written range a prefix.
    pub fn acknowledgeHistory(self: *Region, id: u64) AcknowledgeError!void {
        // Written batches are the prefix [0, history_written).
        for (self.history.items[0..self.history_written]) |*b| {
            if (b.id != id) continue;
            if (b.acked) return error.UnknownHistoryId;
            b.acked = true;
            self.releaseAckedPrefix();
            return;
        }
        return error.UnknownHistoryId;
    }

    /// Transport-level acknowledgement: every batch whose bytes the
    /// output queue took is acknowledged at once, and the receipt ids
    /// are returned in write order. The App calls this when the queue
    /// drained empty — the transport contract for "written exactly
    /// once, acknowledged exactly once".
    pub fn acknowledgeDrained(self: *Region) []const u64 {
        self.history_ids.clearRetainingCapacity();
        // Only the batches whose bytes the transport actually took: a
        // batch that is still staged for a future frame is not
        // acknowledged by a drain of THIS frame.
        for (self.history.items[0..self.history_written]) |*b| {
            if (b.acked) continue;
            b.acked = true;
            self.history_ids.appendAssumeCapacity(b.id);
        }
        self.releaseAckedPrefix();
        return self.history_ids.items;
    }

    /// Release the acknowledged HEAD of the ledger, never a batch out
    /// of the middle: a written batch is only ever released behind the
    /// written batches before it, so the written range stays a prefix
    /// and an unwritten batch can never be mistaken for a written one.
    fn releaseAckedPrefix(self: *Region) void {
        while (self.history.items.len > 0 and self.history.items[0].acked) {
            self.releaseBatch(self.history.orderedRemove(0));
            // Every released item was written, so the written range
            // shortens by one with it.
            if (self.history_written > 0) self.history_written -= 1;
        }
    }

    /// Cells that differ from the previous frame: the damage a `.diff`
    /// frame had to paint. Zero while a frame is uncommitted (a failed
    /// composition leaves `prev` alone), so a caller that measures
    /// damage before `render` never counts a frame twice.
    pub fn dirtyCells(self: *const Region) usize {
        var n: usize = 0;
        for (0..self.cur.height) |y| {
            for (0..self.cur.width) |x| {
                if (!self.cur.get(@intCast(x), @intCast(y)).eql(self.prev.get(@intCast(x), @intCast(y)))) n += 1;
            }
        }
        return n;
    }

    /// Ids the Region still retains: written or not, unacknowledged, in
    /// write order. The slice is valid until the next ledger call.
    pub fn historyPending(self: *Region) []const u64 {
        self.history_pending_buf.clearRetainingCapacity();
        self.history_pending_buf.ensureTotalCapacity(self.gpa, self.history.items.len) catch return &.{};
        for (self.history.items) |b| self.history_pending_buf.appendAssumeCapacity(b.id);
        return self.history_pending_buf.items;
    }

    /// Highest batch id accepted so far.
    pub fn historyWatermark(self: *const Region) u64 {
        return self.history_high;
    }

    /// True while the Region still retains a copy of `id`'s rows.
    pub fn historyRetained(self: *const Region, id: u64) bool {
        for (self.history.items) |b| {
            if (b.id == id) return true;
        }
        return false;
    }

    /// Retained ledger rows and bytes (telemetry + the bound).
    pub fn historyBytes(self: *const Region) usize {
        return self.history_bytes;
    }

    // ── frame ──────────────────────────────────────────

    /// Render one frame into `w` (a std.Io.Writer-compatible writer —
    /// in production, the bounded output queue's staging writer).
    ///
    /// Frame flow: idle check (zero bytes) → envelope prologue (sync,
    /// cursor, autowrap) → CPR re-query when due → strategy → envelope
    /// epilogue (autowrap, sync, cursor) → commit the frame state.
    /// After the frame the cursor sits at the band bottom (column 1 of
    /// the last row). A writer error aborts the frame with NO state
    /// change, so the caller may retry it unchanged.
    pub fn render(self: *Region, w: anytype) !void {
        if (!self.opts.interactive) return self.renderPlain(w);

        const diff = if (self.height == 0) null else self.scanChanges();
        const flush = self.append_queue.items.len > 0 or self.history.items.len > self.history_written;
        const hide_wanted = self.cursor_wanted_hidden;
        const cursor_turn = hide_wanted != self.cursor_hidden;
        const release = self.height == 0 and self.painted_rows > 0;
        const changed = self.first_frame or self.width_dirty or self.height_dirty or
            flush or release or (diff != null) or cursor_turn;
        // Nothing to say: an idle frame emits zero bytes, envelope
        // included. A released band is silent too.
        if (!self.anchor_dirty and !changed) return;
        if (self.height == 0 and !release and !flush and !self.anchor_dirty) return;
        // The only fallible step of a frame, and it runs BEFORE the first
        // byte is staged: on `error.OutOfMemory` the live snapshot,
        // `prev`, the dirty flags and the byte stream are all exactly as
        // they were — no half-written frame and no split state.
        try self.prepareSnapshot();

        var f: Frame = .{};
        const strategy: Strategy = self.planStrategy(release, flush);

        // Envelope prologue: sync, cursor, autowrap.
        if (self.opts.sync_output) try emit.beginSync(w);
        if (hide_wanted and !self.cursor_hidden) {
            try emit.hideCursor(w);
            f.hide_cursor = true;
        }
        try emit.autowrapOff(w);
        if (self.anchor_dirty) {
            try emit.queryCursor(w);
            f.cpr = true;
        }

        switch (strategy) {
            .first => try self.paintFirst(w, &f),
            .collapse => try self.paintCollapse(w, &f),
            .ledger => try self.paintLedger(w, &f),
            .resize => try self.paintResize(w, &f, diff),
            .grow => try self.paintGrow(w, &f, diff),
            .shrink => try self.paintShrink(w, &f, diff),
            .diff => {
                // A diff frame republishes the band's physical extent
                // and high-water mark: both are still exactly what the
                // previous frame left on screen. A CPR-only frame has
                // nothing to repaint, but the bookkeeping still stands.
                f.painted = self.painted_rows;
                f.high_water = self.high_water;
                if (diff) |ch| {
                    try self.paintDiff(w, &f, ch, .{
                        .painted = self.painted_rows,
                        .high_water = self.high_water,
                    });
                } else {
                    try self.park(w);
                }
            },
        }

        // Envelope epilogue: autowrap, sync, cursor restoration.
        try emit.autowrapOn(w);
        if (self.opts.sync_output) try emit.endSync(w);
        if (!hide_wanted and self.cursor_hidden) {
            try emit.showCursor(w);
            f.show_cursor = true;
        }

        self.commit(f);
    }

    /// Exit the interactive session: restore autowrap, show the cursor,
    /// close sync output, and park `\r\n\r` below the last band row —
    /// the final frame stays in the transcript, nothing is cleared.
    /// Idempotent. In piped mode it emits nothing.
    pub fn exit(self: *Region, w: anytype) !void {
        if (self.exited) return;
        self.exited = true;
        if (!self.opts.interactive) return;
        if (self.cursor_hidden) try emit.showCursor(w);
        // Autowrap first: the envelope turns it off, so teardown must
        // turn it back on even if a frame died mid-envelope.
        try emit.autowrapOn(w);
        try emit.endSync(w);
        try w.writeAll("\r\n\r");
    }

    /// The degraded (piped) session's single plain frame: queued
    /// scrollback rows, then every band row as literal text (blank cells
    /// are spaces — a pipe has no cursor state for CUF). No escape
    /// sequences anywhere, styles included; later frames emit nothing.
    ///
    /// A pending `.replay` supersedes the queued appends and every
    /// other unwritten batch exactly as it does interactively: the
    /// replay alone reaches the pipe.
    ///
    /// Transactional like every other frame: a writer that fails leaves
    /// the append queue, the retained batches and the first-frame flag
    /// exactly as they were, so the caller can retry the same frame
    /// instead of losing scrollback to a half-written pipe.
    fn renderPlain(self: *Region, w: anytype) !void {
        if (!self.first_frame) return;
        if (self.pendingReplay()) |at| {
            // The replay restates the whole logical ledger, so it is
            // the only thing the pipe sees.
            for (self.history.items[at].rows) |row| try w.print("{s}\n", .{row});
        } else {
            for (self.append_queue.items) |item| switch (item) {
                .line => |l| try w.print("{s}\n", .{l}),
                .text => |t| try w.print("{s}\n", .{t}),
            };
            for (self.history.items[self.history_written..]) |b| {
                for (b.rows) |row| try w.print("{s}\n", .{row});
            }
        }
        if (self.height > 0) {
            // A pipe never restyles, so nothing is tracked and no
            // trailing reset is owed: the byte stream is plain text.
            var tracked: Style = .{};
            for (0..self.height) |y| {
                if (y > 0) try w.writeByte('\n');
                try self.writeRow(w, y, &tracked, true);
            }
            try w.writeByte('\n');
        }
        // Committed: a pipe has no receipt channel, so the byte stream
        // IS the ledger — the retained copies go now, and the session
        // never renders a second plain frame.
        self.append_queue.clearRetainingCapacity();
        while (self.history.items.len > 0) {
            self.releaseBatch(self.history.orderedRemove(0));
        }
        self.history_written = 0;
        self.first_frame = false;
    }

    /// Frame selection (B3 matrix). Priority: first > collapse > ledger
    /// flush > resize > height delta > diff.
    fn planStrategy(self: *const Region, release: bool, flush: bool) Strategy {
        if (self.first_frame) return .first;
        if (release) return .collapse;
        if (flush) return .ledger;
        if (self.width_dirty) return .resize;
        if (self.height_dirty) return if (self.shrink_rows > 0) .shrink else .grow;
        return .diff;
    }

    // ── frame painters (no state mutation) ─────────────

    /// `first`: write the queued scrollback at the cursor (nothing is
    /// on screen yet, so there is no band to clear), reserve the band
    /// (CNL) and append all `height` rows without clearing. Ends at the
    /// band bottom.
    /// A pending replay claims the whole scrollback stream, so it is
    /// written ALONE: the queued appends it supersedes never reach the
    /// wire.
    fn paintFirst(self: *Region, w: anytype, f: *Frame) !void {
        if (self.pendingReplay() == null and self.append_queue.items.len > 0) {
            try self.writeAppends(w, f);
        }
        if (self.history.items.len > self.history_written) {
            f.anchor_add += try self.writeHistoryBatches(w, f);
        }
        // `append_lines` governs the FIRST band only. A band re-created
        // after a release starts one row below the cursor, and that row
        // is settled content, so the reservation is mandatory: writing
        // in place would overwrite the transcript.
        if ((self.opts.append_lines or self.released) and self.height > 0) {
            try emit.appendLines(w, self.height);
            f.anchor_add += self.height;
        }
        var tracked: Style = .{};
        for (0..self.height) |y| {
            if (y > 0) try w.writeAll("\r\n") else try w.writeAll("\r");
            try self.writeRow(w, y, &tracked, false);
        }
        if (!tracked.eql(Style{})) try w.writeAll(emit.reset);
        try w.writeAll("\r");
        f.painted = self.height;
        f.high_water = self.height;
        f.clear_first = true;
        f.clear_width_dirty = true;
        f.clear_height_dirty = true;
    }

    /// `collapse`: the band reached height 0. The rows stay on screen as
    /// settled content — releasing a band never erases anything, and
    /// never touches the transcript. The cursor parks where it is, on
    /// the row that is now settled content; `commit` publishes the
    /// release, so a frame that dies while staging leaves the band
    /// strategy and the anchor coherent.
    ///
    /// The frame re-queries nothing: a released band has no anchor left
    /// to confirm, and the next frame that re-creates one is the frame
    /// that asks for it (`setHeight`/`resize` mark the anchor suspect).
    fn paintCollapse(self: *const Region, w: anytype, f: *Frame) !void {
        _ = self;
        try w.writeAll("\r");
        f.painted = 0;
        f.high_water = 0;
        f.clear_height_dirty = true;
        f.release = true;
    }

    /// `ledger`: write queued appends and unwritten ledger batches above
    /// the band, then repaint it (the band was erased). ED0 is anchored
    /// at the band top and never reaches above it. A pending replay
    /// claims the whole stream and supersedes the queued appends, which
    /// therefore never reach the wire.
    fn paintLedger(self: *Region, w: anytype, f: *Frame) !void {
        if (self.height > 0) {
            try self.moveToBandTop(w, self.painted_rows);
            try emit.eraseToEnd(w);
        }
        if (self.pendingReplay() == null and self.append_queue.items.len > 0) {
            try self.writeAppends(w, f);
        }
        const rows = try self.writeHistoryBatches(w, f);
        if (self.height > 0) {
            // The rows above pushed the band down by their exact count.
            f.anchor_add += rows;
            try self.paintAll(w, f);
        } else {
            try w.writeAll("\r");
        }
    }

    /// `resize`: a width change, painted according to
    /// `Options.resize_mode` (C2). In every mode the transcript above
    /// the band keeps its rows — a resize never rewrites history.
    fn paintResize(self: *const Region, w: anytype, f: *Frame, diff: ?RowRange) !void {
        const painted = self.painted_rows;
        switch (self.opts.resize_mode) {
            .append => {
                // The anchor does not move: clear the band from its top
                // down (ED0, never above it) and repaint it in place.
                try self.moveToBandTop(w, painted);
                try emit.eraseToEnd(w);
                try self.cur.renderAll(w);
                try w.writeAll("\r");
            },
            .rebuild => {
                // Re-anchor at the live band bottom and repaint
                // downward, so a shorter band leaves its remaining rows
                // on screen as settled content: `renderAll` starts on
                // the cursor's own row (the OLD bottom) and ends on
                // the new one, and the trailing `\r` parks there.
                // That park IS the new band bottom — the row
                // `f.painted` publishes — so no further walk down is
                // emitted: every extra newline would leave the next
                // frame's relative `moveToBandTop` one row low, and the
                // row it skipped is never repainted again.
                try self.cur.renderAll(w);
                try w.writeAll("\r");
                // The band top moved DOWN to the old bottom: track the
                // shift so the anchor stays exact until the CPR reply
                // (`f.anchor_dirty`) confirms it.
                if (painted > 1) f.anchor_add += painted - 1;
            },
            .preserve => {
                // Row-scoped reflow: no ED0 anywhere, so nothing above
                // the band moves and a row the app did not re-lay out
                // is not even touched. Only the rows the reflow actually
                // changed are erased and repainted, each at its own band
                // row.
                try self.moveToBandTop(w, painted);
                try self.cur.renderDiff(&self.prev, w);
                const bottom: u16 = if (diff) |ch| @intCast(ch.last) else 0;
                try self.parkAfter(w, f, bottom, self.height);
            },
        }
        f.painted = self.height;
        f.high_water = self.height;
        f.clear_width_dirty = true;
        f.anchor_dirty = true;
    }

    /// `grow`: the band grew. The new rows are reserved physically (CNL)
    /// so the band exists on screen, then the diff paints them.
    fn paintGrow(self: *const Region, w: anytype, f: *Frame, diff: ?RowRange) !void {
        if (self.grow_rows > 0) {
            try emit.appendLines(w, self.grow_rows);
            f.anchor_add += self.grow_rows;
        }
        f.painted = self.height;
        f.high_water = self.height;
        f.clear_height_dirty = true;
        if (diff) |ch| {
            // The reservation put the cursor at the NEW band bottom, so
            // the diff walks up from `height`, not from the extent the
            // previous frame left behind.
            try self.paintDiff(w, f, ch, .{ .painted = self.height, .high_water = self.height });
        } else {
            // Reserve-only frame: park at the new band bottom.
            try self.park(w);
        }
    }

    /// `shrink`: the band shrank. Erase the removed tail row-scoped
    /// (EL touches only the current row — never content below the band),
    /// counting the PHYSICALLY painted extent, then diff the band.
    fn paintShrink(self: *const Region, w: anytype, f: *Frame, diff: ?RowRange) !void {
        const painted = self.painted_rows;
        if (painted > self.height) {
            try w.writeAll("\r");
            var erased: u16 = 0;
            const removed = painted - self.height;
            while (erased < removed) : (erased += 1) {
                try emit.eraseLine(w);
                if (erased + 1 < removed) try w.writeAll("\x1b[1A");
            }
            try w.writeAll("\r");
            try w.writeAll("\x1b[1A"); // first removed row -> new band bottom
        }
        f.painted = self.height;
        f.high_water = self.height;
        f.clear_height_dirty = true;
        if (diff) |ch| {
            // The walk above left the cursor on the new band bottom and
            // erased every row the new high-water mark no longer owns,
            // so the diff settles from `height`.
            try self.paintDiff(w, f, ch, .{ .painted = self.height, .high_water = self.height });
        } else {
            try self.park(w);
        }
    }

    /// The band's physical extent and high-water mark as THIS frame
    /// settles them. A height change publishes the extent it just
    /// reserved or kept, never the one the previous frame left behind:
    /// the cursor reaches the band's bottom only after this frame's
    /// reservation, and the tail erase may only reach a mark this frame
    /// already settled.
    const Extent = struct { painted: u16, high_water: u16 };

    /// `diff`: steady state. Diff against `prev` from the anchor, then
    /// erase the high-water tail row-scoped.
    fn paintDiff(
        self: *const Region,
        w: anytype,
        f: *Frame,
        ch: RowRange,
        extent: Extent,
    ) !void {
        try self.moveToBandTop(w, extent.painted);
        try self.cur.renderDiff(&self.prev, w);
        var bottom_row: usize = ch.last;
        const content_len = self.contentLen();
        if (content_len < extent.high_water) {
            const hw = extent.high_water;
            const tail_start = @max(content_len, ch.last + 1);
            if (tail_start < hw) {
                try w.writeAll("\r");
                var down = tail_start - ch.last;
                while (down > 0) : (down -= 1) try w.writeByte('\n');
                var y = tail_start;
                while (y < hw) : (y += 1) {
                    try emit.eraseLine(w);
                    if (y + 1 < hw) try w.writeAll("\r\n");
                }
                bottom_row = hw - 1;
            }
            f.high_water = @intCast(content_len);
        }
        try self.parkAfter(w, f, @intCast(bottom_row), extent.painted);
    }

    /// Full repaint of every row after a clear. Entry: cursor at the band
    /// top (column 1 of row 0). Never emits more than `height` rows.
    fn paintAll(self: *const Region, w: anytype, f: *Frame) !void {
        try self.cur.renderAll(w);
        try w.writeAll("\r");
        f.painted = self.height;
        f.high_water = self.height;
    }

    /// Park the cursor at the band bottom (column 1 of the last row).
    fn park(self: *const Region, w: anytype) !void {
        _ = self;
        try w.writeAll("\r");
    }

    /// From the end of row `bottom_row`, walk down to row
    /// `painted - 1` and return column 1 there. Uses the physical band
    /// extent, never `new - old` arithmetic.
    fn parkAfter(self: *const Region, w: anytype, f: *Frame, bottom_row: u16, painted: u16) !void {
        _ = self;
        _ = f;
        try w.writeAll("\r");
        if (painted == 0) return;
        var rest = painted - 1 - @min(bottom_row, painted - 1);
        while (rest > 0) : (rest -= 1) try w.writeByte('\n');
    }

    // ── ledger bytes ──────────────────────────────────

    /// Write every queued item: text `\n` becomes `\r\n`, lines are
    /// verbatim, each item is terminated with `\r\n`. The deterministic
    /// line count shifts the anchor; a text item's row count is
    /// terminal-decided, so the anchor is re-queried next frame.
    fn writeAppends(self: *const Region, w: anytype, f: *Frame) !void {
        for (self.append_queue.items) |item| {
            switch (item) {
                .line => |l| {
                    try w.writeAll(l);
                    try w.writeAll("\r\n");
                    f.anchor_add += 1;
                },
                .text => |t| {
                    var it = std.mem.splitScalar(u8, t, '\n');
                    var first_seg = true;
                    while (it.next()) |seg| {
                        if (!first_seg) try w.writeAll("\r\n");
                        first_seg = false;
                        try w.writeAll(seg);
                    }
                    if (!std.mem.endsWith(u8, t, "\n")) try w.writeAll("\r\n");
                    f.anchor_dirty = true;
                },
            }
        }
        f.took_appends = true;
    }

    /// Write the ledger above the band and return the number of rows
    /// written (the exact anchor shift).
    ///
    /// A pending `.replay` restates the whole logical ledger, so it
    /// goes on the wire ALONE: the appends it supersedes are never
    /// written, and every other unwritten batch is dropped at COMMIT
    /// (`applyReplay`), after this frame's last byte is staged. Nothing
    /// is released before that, so a frame that dies part-way through
    /// the replay — a full output queue, B1 — leaves the whole ledger
    /// and the whole append queue intact and the retry writes the same
    /// complete replay. The written batches in front
    /// (`[0, history_written)`) are never touched: their bytes already
    /// reached the wire, and only an unwritten batch is superseded.
    ///
    /// `f.replay` records the index `commit` supersedes from;
    /// `f.took_appends` drops the queue the replay replaces.
    fn writeHistoryBatches(self: *Region, w: anytype, f: *Frame) !u16 {
        if (self.pendingReplay()) |at| {
            const rows = try writeRows(self.history.items[at].rows, w);
            f.replay = at;
            f.took_appends = true;
            return rows;
        }
        // The write cursor only advances on commit: a frame that fails
        // mid-ledger must leave every batch unwritten.
        var rows: u16 = 0;
        for (self.history.items[self.history_written..]) |b| {
            rows += try writeRows(b.rows, w);
        }
        f.took_history = true;
        return rows;
    }

    /// Index of a `.replay` batch staged but unwritten, or null. The
    /// LAST one wins: each replay states the whole logical ledger, so
    /// the newest is the most complete statement of it.
    fn pendingReplay(self: *const Region) ?usize {
        var found: ?usize = null;
        for (self.history.items[self.history_written..], self.history_written..) |b, i| {
            if (b.kind == .replay) found = i;
        }
        return found;
    }

    /// COMMIT-time supersession: release every unwritten batch the
    /// staged replay replaces, keeping the replay itself, and publish
    /// the write cursor. Runs only after the replay's bytes are staged,
    /// so an aborted frame loses nothing. The removals stay inside
    /// `[history_written, len)`, so the written prefix — and the
    /// receipts that still refer to it — is never disturbed.
    fn applyReplay(self: *Region, at: usize) void {
        var keep = at;
        var j = self.history_written;
        while (j < self.history.items.len) {
            if (j == keep) {
                j += 1;
                continue;
            }
            const dead = self.history.orderedRemove(j);
            self.releaseBatch(dead);
            if (j < keep) keep -= 1;
        }
        self.history_written = self.history.items.len;
    }

    // ── commit ────────────────────────────────────────

    /// Apply a staged frame's state. Runs only after the last byte is
    /// staged, so a failed composition advances nothing (B2).
    fn commit(self: *Region, f: Frame) void {
        if (f.clear_first) {
            self.first_frame = false;
            // The band exists again: the reservation it made is the one
            // the next frames may paint into.
            self.released = false;
        }
        if (f.clear_width_dirty) self.width_dirty = false;
        if (f.clear_height_dirty) {
            self.height_dirty = false;
            self.grow_rows = 0;
            self.shrink_rows = 0;
        }
        if (f.release) {
            self.collapsed = true;
            self.released = true;
        }
        if (f.hide_cursor) self.cursor_hidden = true;
        if (f.show_cursor) self.cursor_hidden = false;
        // A replay supersedes the append queue, so it is dropped with
        // the batches it replaces — both on the wire and in the
        // retained state.
        if (f.took_appends) self.append_queue.clearRetainingCapacity();
        // The physical extent is bookkeeping for cursor moves only. The
        // tracked anchor moves by `anchor_add` alone: the rows a frame
        // physically pushes below the band top (CNL reservations,
        // ledger writes, hard-wrapped appends). A paint that covers rows
        // the terminal already had pushes nothing.
        self.painted_rows = f.painted;
        self.last_width = self.width;
        self.anchor_row +|= f.anchor_add;
        self.high_water = f.high_water;
        if (f.anchor_dirty) self.anchor_dirty = true;
        if (f.cpr) self.anchor_dirty = false;
        if (f.replay) |at| self.applyReplay(at);
        if (f.took_history) self.history_written = self.history.items.len;
        // Infallible: `render` prepared the snapshot before a single
        // byte was staged, so this only publishes it.
        self.publishSnapshot();
    }

    /// Copy the current frame's cell text into the scratch arena and
    /// record the per-cell owned slices. The ONLY fallible step of a
    /// frame, and it runs BEFORE any byte is staged: on
    /// `error.OutOfMemory` the live snapshot, `prev`, the dirty flags
    /// and the byte stream are all exactly as they were — no half-written
    /// frame, no split state, no silent repaint-everything fallback.
    ///
    /// The scratch arena is reset with its capacity retained and the
    /// slice list is reused, so once a session has reached its
    /// high-water mark this allocates nothing per frame.
    fn prepareSnapshot(self: *Region) error{OutOfMemory}!void {
        self.snapshot_cells.clearRetainingCapacity();
        _ = self.snapshot_scratch.reset(.retain_capacity);
        const arena = self.snapshot_scratch.allocator();
        try self.snapshot_cells.ensureTotalCapacity(self.gpa, self.cur.cells.len);
        for (self.cur.cells) |cell| {
            if (cell.grapheme.len == 0) continue;
            // The default blank is a comptime literal — immutable by
            // construction, so it needs no copy, and no other slice can
            // share that address except the same literal.
            if (cell.grapheme.ptr == (Cell{}).grapheme.ptr) continue;
            const owned = try arena.dupe(u8, cell.grapheme);
            self.snapshot_cells.appendAssumeCapacity(owned);
        }
    }

    /// Publish the prepared snapshot: `prev` takes `cur`'s cells with
    /// their text owned by the Region, and the arenas swap so the next
    /// prepare builds in the retired one. Infallible by construction.
    fn publishSnapshot(self: *Region) void {
        @memcpy(self.prev.cells, self.cur.cells);
        // Cells with no text keep `cur`'s (empty) slice, which has
        // nothing to own; every other cell takes its prepared copy.
        var next: usize = 0;
        for (self.prev.cells) |*cell| {
            if (cell.grapheme.len == 0) continue;
            if (cell.grapheme.ptr == (Cell{}).grapheme.ptr) continue;
            cell.grapheme = self.snapshot_cells.items[next];
            next += 1;
        }
        std.mem.swap(std.heap.ArenaAllocator, &self.prev_text, &self.snapshot_scratch);
    }

    // ── cursor moves (relative only) ───────────────────

    /// Move from the band bottom to the band top: `\r` + CUU. The one
    /// upward relative move; the anchor is never positioned absolutely
    /// (grep-gate: `placeAt` is the file's only absolute positioning
    /// call — it restores the parked cursor). `painted` is the physical
    /// extent, not `height`.
    fn moveToBandTop(self: *const Region, w: anytype, painted: u16) !void {
        _ = self;
        try w.writeAll("\r");
        if (painted > 1) try w.print("\x1b[{d}A", .{painted - 1});
    }

    // ── diff bookkeeping ──────────────────────────────

    const RowRange = struct { first: usize, last: usize };

    /// Rows of `cur` that differ from `prev`, or null when equal (idle).
    fn scanChanges(self: *const Region) ?RowRange {
        var first: ?usize = null;
        var last: usize = 0;
        for (0..self.cur.height) |y| {
            if (self.rowEqual(y)) continue;
            if (first == null) first = y;
            last = y;
        }
        const f = first orelse return null;
        return .{ .first = f, .last = last };
    }

    /// Whether row `y` is unchanged. Safe because `prev` OWNS the
    /// previous frame's text (see `prepareSnapshot`): a compare can
    /// never read bytes the app has since rewritten in place.
    fn rowEqual(self: *const Region, y: usize) bool {
        for (0..self.cur.width) |x| {
            if (!self.cur.get(@intCast(x), @intCast(y)).eql(self.prev.get(@intCast(x), @intCast(y)))) return false;
        }
        return true;
    }

    /// Number of rows the current frame occupies: index of the last
    /// non-empty row plus one (0 when the band is empty).
    fn contentLen(self: *const Region) usize {
        var y = self.cur.height;
        while (y > 0) {
            y -= 1;
            if (self.rowNonEmpty(y)) return y + 1;
        }
        return 0;
    }

    fn rowNonEmpty(self: *const Region, y: usize) bool {
        for (0..self.cur.width) |x| {
            if (!self.cur.get(@intCast(x), @intCast(y)).eql(Cell{})) return true;
        }
        return false;
    }

    // ── row emission ──────────────────────────────────

    /// Write one row's cells (entry: cursor at column 1 of the row).
    /// Mirrors `Buffer.writeRow`: wide continuations never emit text
    /// (their column was covered by the lead's write); SGR is written
    /// only on style change (libvaxis DAM pattern). Interactive rows
    /// (`plain = false`) skip blank cells — the row's erase or the next
    /// cell's CUF covers the gap — while plain (piped) rows write
    /// literal spaces: a pipe has no cursor state for CUF to move, so
    /// skipped blanks would vanish from the byte stream.
    ///
    /// A plain row also writes no SGR at all, styled cells included: a
    /// pipe is a byte sink, so a `CSI m` would land in the transcript
    /// as literal garbage. `tracked` is only advanced on the
    /// interactive path.
    fn writeRow(self: *const Region, w: anytype, y: usize, tracked: *Style, plain: bool) !void {
        var x: usize = 0;
        var phys_col: usize = 0; // terminal cursor column, 0-indexed
        while (x < self.cur.width) {
            const cell = self.cur.get(@intCast(x), @intCast(y));

            // Wide continuations never emit text; their column was
            // covered by the lead's write (which advances 2).
            if (cell.wide) {
                x += 1;
                continue;
            }
            // Blank cells (default `Cell{}` carries a " " grapheme, and
            // empty-grapheme cells are blank too). Interactive rows skip
            // them; plain rows write the space byte.
            if (cell.grapheme.len == 0 or cell.eql(Cell{})) {
                if (plain) {
                    try w.writeByte(' ');
                    phys_col += 1;
                }
                x += 1;
                continue;
            }

            const wg = Width.graphemeWidth(cell.grapheme);
            const wcell: usize = if (wg >= 2) 2 else 1;
            // A wide glyph at the last column has no continuation cell;
            // drop it (graceful — over-wide never errors). A plain row
            // still reserves the column as a space so the byte stream
            // stays width-aligned.
            if (x + wcell > self.cur.width) {
                if (plain) {
                    try w.writeByte(' ');
                    phys_col += 1;
                }
                x += 1;
                continue;
            }

            // CUF and SGR are interactive-only: a pipe has no cursor
            // state to move and no terminal to restyle, so a plain row
            // emits the grapheme alone.
            if (!plain) {
                if (x > phys_col) try w.print("\x1b[{d}C", .{x - phys_col});
                try writeCellStyle(w, tracked, cell.style);
                phys_col = x + wcell;
            }
            try w.writeAll(cell.grapheme);
            x += wcell;
        }
    }

    fn releaseBatch(self: *Region, b: OwnedBatch) void {
        for (b.rows) |row| self.gpa.free(row);
        self.gpa.free(b.rows);
        self.history_bytes -= b.bytes;
    }
};

/// Emit SGR for `style` only when it differs from the last emitted
/// style (`tracked`), updating `tracked` on change. Turning fields off
/// requires a full reset first (`emit.writeStyle` emits only non-default
/// fields); a fully-default target style emits just the reset.
fn writeCellStyle(w: anytype, tracked: *Style, style: Style) !void {
    if (tracked.eql(style)) return;
    if (!tracked.eql(Style{})) try w.writeAll(emit.reset);
    if (!style.eql(Style{})) try emit.writeStyle(w, style);
    tracked.* = style;
}

/// Write `rows` one exact terminal row each, CRLF terminated, and
/// return how many rows reached the wire (the exact anchor shift).
fn writeRows(rows: []const []u8, w: anytype) !u16 {
    var written: u16 = 0;
    for (rows) |row| {
        try w.writeAll(row);
        try w.writeAll("\r\n");
        written += 1;
    }
    return written;
}

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;
const output = @import("output.zig");

// ── envelope fragments ────────────────────────────────
const sync_on = "\x1b[?2026h";
const sync_off = "\x1b[?2026l";
const hide_c = "\x1b[?25l";
const show_c = "\x1b[?25h";
const aw_off = "\x1b[?7l";
const aw_on = "\x1b[?7h";
const cpr_q = "\x1b[6n";

/// Fixed-buffer writer for byte-exact assertions (emit.zig TestWriter
/// pattern). `init` must run in place — the writer borrows `buf`.
const TestWriter = struct {
    buf: [4096]u8 = undefined,
    w: std.Io.Writer = undefined,

    fn init(self: *TestWriter) void {
        self.w = .fixed(&self.buf);
    }

    fn bytes(self: *const TestWriter) []const u8 {
        return self.w.buffered();
    }
};

const RegionMode = struct {
    interactive: bool = true,
    sync: bool = true,
    append_lines: bool = false,
    mode: ResizeMode = .append,
    max_history: usize = 256 * 1024,
};

fn makeRegion(h: u16, m: RegionMode) !Region {
    return Region.init(testing.allocator, .{
        .height = h,
        .interactive = m.interactive,
        .sync_output = m.sync,
        .append_lines = m.append_lines,
        .resize_mode = m.mode,
        .max_history_bytes = m.max_history,
    });
}

fn drawRow(buf: *Buffer, y: u16, text: []const u8) !void {
    _ = try buf.draw(Style{}, text, 0, y);
}

/// The same text in every band row: the content most erase, diff and
/// reflow tests drive, and it keeps the expected bytes readable.
fn fillBand(buf: *Buffer, text: []const u8) !void {
    for (0..buf.height) |y| try drawRow(buf, @intCast(y), text);
}

fn clearRow(buf: *Buffer, y: u16, cols: u16) !void {
    for (0..cols) |x| try buf.set(@intCast(x), y, .{});
}

fn count(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

/// A completed interactive frame: envelope prologue, body, epilogue.
/// `comptime` because the whole frame is a string constant — every
/// caller passes a literal.
fn framed(comptime body: []const u8) []const u8 {
    return sync_on ++ aw_off ++ body ++ aw_on ++ sync_off;
}

/// A terminal model for the frames the Region emits: it interprets the
/// C0 and CSI subset of the byte stream — CR, LF, CUU/CUD/CUF/CUB,
/// CNL/CPL, CHA, CUP, ED0, EL — and records where every printable
/// byte lands. SGR, DEC private modes and the CPR query are ignored:
/// they move no cursor and paint no cell.
///
/// This is the CONSUMER's view. Where a proof only needs "did the text
/// land on the row the band owns", that beats pinning the exact escape
/// bytes: the bytes are an implementation detail, the row is the
/// contract.
const Term = struct {
    const rows = 24;
    const cols = 80;
    const blank: [cols]u8 = [_]u8{' '} ** cols;

    grid: [rows][cols]u8 = [_][cols]u8{blank} ** rows,

    row: usize = 0,
    col: usize = 0,

    fn feed(self: *Term, bytes: []const u8) void {
        var i: usize = 0;
        while (i < bytes.len) {
            switch (bytes[i]) {
                '\x1b' => i = self.esc(bytes, i),
                '\r' => {
                    self.col = 0;
                    i += 1;
                },
                // LF keeps the column: the renderer always writes the
                // CR itself, so this stays exact.
                '\n' => {
                    self.row = @min(self.row + 1, rows - 1);
                    i += 1;
                },
                else => {
                    if (bytes[i] < 0x20) {
                        i += 1;
                        continue;
                    }
                    self.grid[self.row][self.col] = bytes[i];
                    self.col = @min(self.col + 1, cols - 1);
                    i += 1;
                },
            }
        }
    }

    /// Parse one escape sequence starting at `i` (on its ESC) and
    /// return the index just past it.
    fn esc(self: *Term, bytes: []const u8, i: usize) usize {
        var p = i + 1;
        if (p >= bytes.len) return p;
        if (bytes[p] != '[') return p + 1; // not CSI (ESC ] , ESC \ …)
        p += 1;
        // DEC private prefix: `?25l`, `>4;2m`, …
        if (p < bytes.len and (bytes[p] == '?' or bytes[p] == '>' or bytes[p] == '<')) p += 1;
        var params: [2]u16 = .{ 0, 0 };
        var n: usize = 0;
        while (p < bytes.len) : (p += 1) {
            const c = bytes[p];
            if (c >= '0' and c <= '9') {
                if (n < params.len) {
                    params[n] = params[n] * 10 + (c - '0');
                }
                continue;
            }
            if (c == ';') {
                n += 1;
                continue;
            }
            self.apply(c, params);
            return p + 1;
        }
        return p;
    }

    /// Apply one final-byte CSI. `params[0]` is 0 when omitted, which
    /// every default treats as 1.
    fn apply(self: *Term, final: u8, params: [2]u16) void {
        const a: usize = if (params[0] == 0) 1 else params[0];
        const r = self.row;
        const c = self.col;
        switch (final) {
            'A' => self.row = if (r > a) r - a else 0, // CUU
            'B' => self.row = @min(r + a, rows - 1), // CUD
            'C' => self.col = @min(c + a, cols - 1), // CUF
            'D' => self.col = if (c > a) c - a else 0, // CUB
            'E' => { // CNL
                self.row = @min(r + a, rows - 1);
                self.col = 0;
            },
            'F' => { // CPL
                self.row = if (r > a) r - a else 0;
                self.col = 0;
            },
            'G' => self.col = @min(a -| 1, cols - 1), // CHA
            'H', 'f' => { // CUP
                self.row = @min(@as(usize, params[0]) -| 1, rows - 1);
                self.col = @min(@as(usize, params[1]) -| 1, cols - 1);
            },
            'J' => switch (params[0]) { // ED
                0 => self.eraseBelow(r, c),
                2 => self.grid = [_][cols]u8{blank} ** rows,
                else => {},
            },
            'K' => switch (params[0]) { // EL
                0 => self.eraseLineFrom(r, c),
                1 => self.eraseLineTo(r, c),
                else => {},
            },
            'h', 'l', 'm', 'n', 'r' => {}, // modes, SGR, queries: no geometry
            else => {},
        }
    }

    /// Blank cells from (`r`, `c`) to the end of row `r`.
    fn eraseLineFrom(self: *Term, r: usize, c: usize) void {
        for (self.grid[r][c..]) |*cell| cell.* = ' ';
    }

    /// Blank cells from column 0 through (`r`, `c`), inclusive.
    fn eraseLineTo(self: *Term, r: usize, c: usize) void {
        for (self.grid[r][0 .. c + 1]) |*cell| cell.* = ' ';
    }

    /// Blank cells from (`r`, `c`) to the bottom-right of the screen.
    fn eraseBelow(self: *Term, r: usize, c: usize) void {
        self.eraseLineFrom(r, c);
        for (self.grid[r + 1 ..]) |*line| @memset(line, ' ');
    }

    /// Row `r` as text, trailing blanks removed.
    fn text(self: *const Term, r: usize) []const u8 {
        var line: []const u8 = &self.grid[r];
        while (line.len > 0 and line[line.len - 1] == ' ') line = line[0 .. line.len - 1];
        return line;
    }
};

// ── options ───────────────────────────────────────────

test "region: options default to an interactive synced session" {
    const o: Region.Options = .{ .height = 3 };
    try testing.expect(o.append_lines);
    try testing.expect(o.interactive);
    try testing.expect(o.sync_output);
    try testing.expectEqual(ResizeMode.append, o.resize_mode);
    try testing.expectEqual(caps.Capabilities.WidthPolicy.zg_unicode, o.width_policy);
    try testing.expectEqual(@as(usize, 256 * 1024), o.max_history_bytes);
}

test "region: init/deinit leak nothing with a queue and a ledger" {
    var r = try Region.init(testing.allocator, .{ .height = 3 });
    defer r.deinit();
    try r.append(.{ .text = "one" });
    try r.append(.{ .line = "two" });
    try r.append(.{ .line = "three" });
    try r.writeHistory(.{ .id = 1, .rows = &.{"kept"}, .kind = .append });
    // Acknowledged: the retained copy is released before deinit.
    _ = r.acknowledgeDrained();
}

// ── B2: the paint envelope ────────────────────────────

test "region: the first frame is wrapped once: sync, hide, autowrap off, body, on, end" {
    var r = try makeRegion(2, .{ .append_lines = true });
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    try testing.expectEqualStrings(
        sync_on ++ hide_c ++ aw_off ++ cpr_q ++ "\x1b[2E" ++ "\rab\r\ncd\r" ++ aw_on ++ sync_off,
        t.bytes(),
    );
    try testing.expect(r.cursor_hidden);
    try testing.expectEqual(@as(u16, 2), r.high_water);
}

test "region: an interactive session without DEC 2026 paints normally, envelope minus sync" {
    var r = try makeRegion(1, .{ .sync = false });
    defer r.deinit();
    try drawRow(&r.cur, 0, "hi");

    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    try testing.expectEqualStrings(hide_c ++ aw_off ++ cpr_q ++ "\rhi\r" ++ aw_on, t.bytes());
    try testing.expectEqual(@as(usize, 0), count(t.bytes(), sync_on));
    try testing.expectEqual(@as(usize, 0), count(t.bytes(), sync_off));

    // A changed frame keeps painting (no sync bytes, still one envelope).
    try clearRow(&r.cur, 0, 2);
    try drawRow(&r.cur, 0, "yo");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    // `moveToBandTop` parks at the band top with a bare CR for a one-row
    // band, then the diff re-arms the column and erases the row it
    // repaints — the same `\r\r\x1b[K` shape every diff frame emits.
    try testing.expectEqualStrings(aw_off ++ "\r\r\x1b[Kyo\r" ++ aw_on, t2.bytes());
}

test "region: the envelope hides and shows the cursor on the transition frames only" {
    var r = try makeRegion(1, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "a");

    // Frame 1: the app wants the cursor hidden — hide at the start.
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    try testing.expectEqual(@as(usize, 1), count(t1.bytes(), hide_c));

    // Frame 2: unchanged content, cursor still wanted hidden: no bytes.
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try testing.expectEqualStrings("", t2.bytes());

    // Frame 3: the app now wants a visible cursor — the epilogue shows
    // it at the end of the frame that changed the desire.
    r.setCursorHidden(false);
    try clearRow(&r.cur, 0, 1);
    try drawRow(&r.cur, 0, "b");
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    try testing.expectEqualStrings(
        sync_on ++ aw_off ++ "\r\r\x1b[Kb\r" ++ aw_on ++ sync_off ++ show_c,
        t3.bytes(),
    );
    try testing.expect(!r.cursor_hidden);

    // Frame 4: back to hidden — the prologue hides it again.
    r.setCursorHidden(true);
    try clearRow(&r.cur, 0, 1);
    try drawRow(&r.cur, 0, "c");
    var t4: TestWriter = .{};
    t4.init();
    try r.render(&t4.w);
    // The prologue order is sync, cursor, autowrap: the hide lands
    // inside the sync bracket, ahead of the autowrap-off.
    try testing.expectEqualStrings(
        sync_on ++ hide_c ++ aw_off ++ "\r\r\x1b[Kc\r" ++ aw_on ++ sync_off,
        t4.bytes(),
    );
}

test "region: an idle frame emits zero bytes, envelope included" {
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    try testing.expect(t1.bytes().len > 0);

    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try testing.expectEqualStrings("", t2.bytes());
}

test "region: a forced full redraw happens once, then the band is idle again" {
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "aa");
    try drawRow(&r.cur, 1, "bb");
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    try testing.expectEqual(@as(usize, 0), count(t1.bytes(), "\x1b[J"));

    // The content did not change, but a forced redraw repaints the WHOLE
    // band from the anchor in one frame: the band-top move and the ED0
    // a plain diff would never emit.
    var t2: TestWriter = .{};
    t2.init();
    try r.renderFull(&t2.w);
    try testing.expectEqual(@as(usize, 1), count(t2.bytes(), "\x1b[J"));
    try testing.expectEqual(@as(usize, 1), count(t2.bytes(), "aa"));
    try testing.expectEqual(@as(usize, 1), count(t2.bytes(), "bb"));

    // The request is spent, not latched: one re-anchor frame (a width
    // change makes the tracked anchor suspect), then byte-empty idles
    // for the rest of the session.
    try testing.expect(!r.width_dirty);
    try testing.expect(r.anchor_dirty);
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    try testing.expectEqualStrings(framed(cpr_q ++ "\r"), t3.bytes());
    try testing.expect(!r.anchor_dirty);
    var t4: TestWriter = .{};
    t4.init();
    try r.render(&t4.w);
    try testing.expectEqualStrings("", t4.bytes());
}

test "region: exit restores the cursor, autowrap, sync, and parks below the band" {
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    var t2: TestWriter = .{};
    t2.init();
    try r.exit(&t2.w);
    try testing.expectEqualStrings(show_c ++ aw_on ++ sync_off ++ "\r\n\r", t2.bytes());
}

test "region: exit is idempotent" {
    var r = try makeRegion(2, .{});
    defer r.deinit();
    var t1: TestWriter = .{};
    t1.init();
    try r.exit(&t1.w); // nothing was ever hidden
    try testing.expectEqualStrings(aw_on ++ sync_off ++ "\r\n\r", t1.bytes());

    var t2: TestWriter = .{};
    t2.init();
    try r.exit(&t2.w);
    try testing.expectEqualStrings("", t2.bytes());
}

test "region: piped mode emits one plain frame and ignores sync_output" {
    // `interactive = false` is the only gate: sync_output is not consulted.
    var r = try makeRegion(2, .{ .interactive = false, .sync = true, .append_lines = true });
    defer r.deinit();
    try r.resize(4, 2);
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    try testing.expectEqualStrings(
        "ab  \ncd  \n",
        t.bytes(),
    );
    try testing.expect(std.mem.indexOf(u8, t.bytes(), "\x1b[") == null);

    // Later frames change nothing in a pipe: no repaint, no erase.
    try clearRow(&r.cur, 0, 4);
    try drawRow(&r.cur, 0, "zz");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try testing.expectEqualStrings("", t2.bytes());

    // Exit parks nothing in piped mode.
    var t3: TestWriter = .{};
    t3.init();
    try r.exit(&t3.w);
    try testing.expectEqualStrings("", t3.bytes());
}

test "region: piped rows write blank cells as spaces, never CUF" {
    var r = try makeRegion(2, .{ .interactive = false });
    defer r.deinit();
    try drawRow(&r.cur, 0, "a  b");

    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    const out = t.bytes();
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[") == null);
    try testing.expectEqualStrings("a  b", out[0..4]);
    try testing.expectEqual(' ', out[81]);
    try testing.expectEqual(' ', out[160]);
    try testing.expectEqual('\n', out[161]);
    try testing.expectEqual(@as(usize, 162), out.len);
}

test "region: piped output carries no escape byte, styled cells included" {
    // A pipe is a byte sink: a `CSI m` would land in the transcript as
    // literal garbage, so a styled cell writes its glyph alone.
    var r = try makeRegion(1, .{ .interactive = false });
    defer r.deinit();
    try r.resize(4, 1);
    _ = try r.cur.draw(.{ .fg = .{ .ansi = .red }, .attrs = .{ .bold = true } }, "hi", 0, 0);
    _ = try r.cur.draw(.{ .bg = .{ .ansi256 = 200 } }, "yo", 2, 0);

    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    try testing.expectEqualStrings("hiyo\n", t.bytes());
    try testing.expectEqual(@as(usize, 0), count(t.bytes(), "\x1b"));
}

test "region: a piped frame that fails advances nothing and retries whole" {
    var r = try makeRegion(2, .{ .interactive = false });
    defer r.deinit();
    try r.resize(4, 2);
    try r.append(.{ .line = "queued" });
    try r.writeHistory(.{ .id = 1, .rows = &.{"ledger"}, .kind = .append });
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    // A pipe that fills up part-way through the frame: the frame dies
    // with the scrollback half written.
    var tiny: [8]u8 = undefined;
    var narrow: std.Io.Writer = .fixed(&tiny);
    try testing.expectError(error.WriteFailed, r.render(&narrow));
    // Nothing moved: the queued line, the retained batch and the
    // first-frame flag are all exactly as they were.
    try testing.expect(r.first_frame);
    try testing.expectEqual(@as(usize, 1), r.append_queue.items.len);
    try testing.expect(r.historyRetained(1));
    try testing.expectEqual(@as(usize, 0), r.history_written);
    try testing.expect(r.historyRetained(1));

    // The retry writes the whole frame, every row exactly once.
    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    try testing.expectEqualStrings("queued\nledger\nab  \ncd  \n", t.bytes());
    try testing.expect(!r.first_frame);
    try testing.expectEqual(@as(usize, 0), r.historyPending().len);
    try testing.expectEqual(@as(usize, 0), r.historyBytes());
}

// ── B2: transactional frames ──────────────────────────

test "region: a frame that does not fit the queue stages nothing" {
    // The real staging writer (B1): a full queue fails the composition.
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try r.append(.{ .line = "queued" });
    try r.writeHistory(.{ .id = 1, .rows = &.{"ledger"}, .kind = .append });
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    var q = try output.OutputQueue.init(testing.allocator, .{ .capacity = 24, .watermark = 16 });
    defer q.deinit();
    q.beginFrame();
    try testing.expectError(error.WriteFailed, r.render(q.writer()));
    try testing.expect(q.frameOverflowed());
    q.abortFrame();

    // Nothing advanced: the frame is still owed, whole.
    try testing.expect(r.first_frame);
    try testing.expect(r.cursor_hidden == false);
    try testing.expectEqual(@as(usize, 1), r.append_queue.items.len);
    try testing.expectEqual(@as(usize, 0), r.history_written);
    try testing.expect(r.historyRetained(1));
    try testing.expectEqual(@as(usize, 1), r.historyPending().len);
    try testing.expectEqual(@as(usize, 0), q.pending());

    // The retry produces the complete frame.
    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    try testing.expectEqualStrings(
        sync_on ++ hide_c ++ aw_off ++ cpr_q ++ "queued\r\nledger\r\n" ++
            "\rab\r\ncd\r" ++ aw_on ++ sync_off,
        t.bytes(),
    );
    try testing.expectEqual(@as(usize, 0), r.append_queue.items.len);
    try testing.expectEqual(@as(usize, 1), r.history_written);
}

test "region: an aborted frame never publishes the snapshot" {
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "aa");
    try drawRow(&r.cur, 1, "bb");
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    // Real damage on row 0, in a frame the queue cannot hold.
    try clearRow(&r.cur, 0, 2);
    try drawRow(&r.cur, 0, "cc");
    var q = try output.OutputQueue.init(testing.allocator, .{ .capacity = 20, .watermark = 10 });
    defer q.deinit();
    q.beginFrame();
    try testing.expectError(error.WriteFailed, r.render(q.writer()));
    q.abortFrame();

    // The snapshot is still the last COMMITTED frame, so the damage is
    // still real: the retry paints the changed row in full rather than
    // deciding it was already on screen.
    try testing.expect(r.dirtyCells() > 0);
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try testing.expectEqual(@as(usize, 1), count(t2.bytes(), "cc"));
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "aa"));
}

// ── B3: strategies and the erase matrix ───────────────

test "region: the first frame appends height rows without clearing" {
    var r = try makeRegion(2, .{ .append_lines = true });
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    try testing.expectEqual(@as(usize, 0), count(t.bytes(), "\x1b[J")); // no ED0
    try testing.expectEqual(@as(usize, 0), count(t.bytes(), "\x1b[K")); // no EL
}

test "region: a changed middle row emits a minimal diff" {
    var r = try makeRegion(3, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "aaa");
    try drawRow(&r.cur, 1, "bbb");
    try drawRow(&r.cur, 2, "ccc");

    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    try testing.expectEqualStrings(
        sync_on ++ hide_c ++ aw_off ++ cpr_q ++ "\raaa\r\nbbb\r\nccc\r" ++ aw_on ++ sync_off,
        t1.bytes(),
    );

    try clearRow(&r.cur, 1, 3);
    try drawRow(&r.cur, 1, "BB");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try testing.expectEqualStrings(
        framed("\r\x1b[2A\r\n\x1b[KBB\r\n"),
        t2.bytes(),
    );
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "\x1b[6n")); // no re-query
}

test "region: the high-water tail is erased row-scoped, never screen-wide" {
    var r = try makeRegion(3, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "aaa");
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    try clearRow(&r.cur, 0, 3);
    try drawRow(&r.cur, 0, "aa");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try testing.expectEqualStrings(framed("\r\x1b[2A\r\x1b[Kaa\r\n\x1b[K\r\n\x1b[K\r"), t2.bytes());
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "\x1b[J"));
    try testing.expectEqual(@as(u16, 1), r.high_water);
}

test "region: a queued line flushes verbatim before the first frame's rows" {
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try r.append(.{ .line = "L" });
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    try testing.expectEqualStrings(
        sync_on ++ hide_c ++ aw_off ++ cpr_q ++ "L\r\n\rab\r\ncd\r" ++ aw_on ++ sync_off,
        t.bytes(),
    );
    try testing.expectEqual(@as(usize, 0), count(t.bytes(), "\x1b[J"));
}

test "region: a steady-state flush erases from the band anchor and repaints" {
    var r = try makeRegion(3, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "aaa");
    try drawRow(&r.cur, 1, "bbb");
    try drawRow(&r.cur, 2, "ccc");
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    try r.append(.{ .text = "a\nb" });
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try testing.expectEqualStrings(
        framed("\r\x1b[2A\x1b[Ja\r\nb\r\n\r\x1b[Kaaa\r\n\x1b[Kbbb\r\n\x1b[Kccc\r"),
        t2.bytes(),
    );
    // The queue drains per frame; text wrap is terminal-decided, so the
    // anchor is re-queried next frame.
    try testing.expectEqual(@as(usize, 0), r.append_queue.items.len);
    try testing.expect(r.anchor_dirty);
}

test "region: a line item shifts the anchor deterministically" {
    var r = try makeRegion(3, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "aaa");
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    try testing.expectEqual(@as(u16, 0), r.anchor_row);

    try r.append(.{ .line = "one" });
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try testing.expectEqual(@as(u16, 1), r.anchor_row);

    try r.append(.{ .line = "two" });
    try r.append(.{ .line = "three" });
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    try testing.expectEqual(@as(u16, 3), r.anchor_row);
}

test "region: grow reserves the new rows with CNL even without append_lines" {
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    try r.setHeight(4);
    try drawRow(&r.cur, 2, "ef");
    try drawRow(&r.cur, 3, "gh");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    // The reservation is physical: a band that does not exist cannot be
    // painted. CNL, then the diff of the new rows, then the park.
    try testing.expectEqualStrings(
        framed("\x1b[2E\r\x1b[3A\r\n\n\x1b[Kef\r\n\x1b[Kgh\r"),
        t2.bytes(),
    );
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "\x1b[J"));
    try testing.expectEqual(@as(u16, 4), r.painted_rows);
    try testing.expect(!r.height_dirty);
}

test "region: shrink erases the removed tail row by row, then diffs" {
    var r = try makeRegion(5, .{});
    defer r.deinit();
    for (0..5) |y| try drawRow(&r.cur, @intCast(y), "abcdef"[y..][0..2]);

    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    try r.setHeight(2);
    try clearRow(&r.cur, 1, 2);
    try drawRow(&r.cur, 1, "XY");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    // Per-row EL walk over the removed rows [2..5), then the diff.
    try testing.expectEqualStrings(
        framed("\r\x1b[K\x1b[1A\x1b[K\x1b[1A\x1b[K\r\x1b[1A\r\x1b[1A\r\n\x1b[KXY\r"),
        t2.bytes(),
    );
    try testing.expectEqual(@as(usize, 4), count(t2.bytes(), "\x1b[K"));
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "\x1b[J"));
    try testing.expectEqual(@as(u16, 2), r.painted_rows);
}

test "region: height zero collapses the band without erasing anything" {
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    try r.setHeight(0);
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    // Release only: the cursor parks, nothing is erased (the rows stay
    // on screen as settled content).
    try testing.expectEqualStrings(framed("\r"), t2.bytes());
    try testing.expectEqual(@as(u16, 0), r.painted_rows);

    // A collapsed band is silent until it grows again.
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    try testing.expectEqualStrings("", t3.bytes());

    // Growing back re-reserves from the cursor and appends the rows.
    try r.setHeight(2);
    try drawRow(&r.cur, 0, "zz");
    try drawRow(&r.cur, 1, "yy");
    var t4: TestWriter = .{};
    t4.init();
    try r.render(&t4.w);
    try testing.expectEqualStrings(framed(cpr_q ++ "\x1b[2E\rzz\r\nyy\r"), t4.bytes());
    try testing.expectEqual(@as(u16, 2), r.painted_rows);
}

test "region: no strategy emits ED2 or ED3, and ED0 only from the band anchor" {
    // The tmux/conhost matrix: drive every strategy in EVERY resize
    // mode, then audit the bytes. ED2 (`ESC[2J`) and ED3 (`ESC[3J`)
    // must never appear: they would destroy scrollback above the band.
    // ED0 may only appear where the cursor has just been moved to the
    // band top — the ledger flush always, and the `.append` resize.
    const Capture = struct {
        fn add(list: *std.ArrayListUnmanaged(u8), t: *const TestWriter) !void {
            try list.appendSlice(testing.allocator, t.bytes());
        }
    };
    for ([_]ResizeMode{ .append, .rebuild, .preserve }) |mode| {
        var r = try makeRegion(3, .{ .append_lines = true, .mode = mode });
        defer r.deinit();
        try fillBand(&r.cur, "abc");

        var all: std.ArrayListUnmanaged(u8) = .empty;
        defer all.deinit(testing.allocator);

        var t: TestWriter = .{};
        t.init();
        try r.render(&t.w);
        try Capture.add(&all, &t); // first

        try r.append(.{ .line = "flush" });
        t.init();
        try r.render(&t.w);
        try Capture.add(&all, &t); // ledger

        try r.setHeight(5);
        t.init();
        try r.render(&t.w);
        try Capture.add(&all, &t); // grow

        try r.setHeight(2);
        t.init();
        try r.render(&t.w);
        try Capture.add(&all, &t); // shrink

        try r.resize(40, 2);
        t.init();
        try r.render(&t.w);
        try Capture.add(&all, &t); // resize (this mode)

        try clearRow(&r.cur, 0, 40);
        try drawRow(&r.cur, 0, "zz");
        t.init();
        try r.render(&t.w);
        try Capture.add(&all, &t); // diff

        try r.setHeight(0);
        t.init();
        try r.render(&t.w);
        try Capture.add(&all, &t); // collapse

        const bytes = all.items;
        try testing.expectEqual(@as(usize, 0), count(bytes, "\x1b[2J"));
        try testing.expectEqual(@as(usize, 0), count(bytes, "\x1b[3J"));
        // No mode ever enters the alternate screen.
        try testing.expectEqual(@as(usize, 0), count(bytes, "\x1b[?1049"));
        // ED0: one for the ledger flush, and one more only for the
        // `.append` resize, which repaints the band in place. `rebuild`
        // and `preserve` stay row-scoped, so a width change adds none.
        const expected: usize = if (mode == .append) 2 else 1;
        try testing.expectEqual(expected, count(bytes, "\x1b[J"));
        // Every ED0 in the session is issued from the band top: the
        // byte before it is the end of `moveToBandTop`, which is a bare
        // CR for a one-row band and a CUU otherwise.
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, bytes, at, "\x1b[J")) |erase| {
            const from_top = erase >= 1 and (bytes[erase - 1] == '\r' or
                (bytes[erase - 1] == 'A' and erase >= 5 and bytes[erase - 5] == '\r'));
            try testing.expect(from_top);
            at = erase + 3;
        }
    }
}

test "region: an ED0 in a flush is always preceded by the band-top move" {
    var r = try makeRegion(3, .{});
    defer r.deinit();
    try fillBand(&r.cur, "abc");
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    try r.append(.{ .line = "flush" });
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    const at = std.mem.indexOf(u8, t2.bytes(), "\x1b[J").?;
    // `\r` + CUU(painted - 1) immediately before the erase: the move is
    // CR plus a three-byte CSI (5 bytes), so the window starts 5 bytes
    // back and spans the 3-byte ED0.
    try testing.expectEqualStrings("\r\x1b[2A\x1b[J", t2.bytes()[at - 5 .. at + 3]);
}

// ── C1: the ledger ────────────────────────────────────

test "region: a batch is written once and acknowledged once" {
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    try r.writeHistory(.{ .id = 7, .rows = &.{ "one", "two" }, .kind = .append });

    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    // The rows land above the band, in order, once.
    try testing.expectEqual(@as(usize, 1), count(t1.bytes(), "one\r\n"));
    try testing.expectEqual(@as(usize, 1), count(t1.bytes(), "two\r\n"));
    // One receipt outstanding.
    try testing.expectEqual(@as(usize, 1), r.historyPending().len);
    try testing.expectEqual(@as(u64, 7), r.historyPending()[0]);
    try testing.expect(r.historyRetained(7));
    try testing.expectEqual(@as(u16, 2), r.anchor_row);

    // The transport drained: acknowledge once, receipts released.
    const receipts = r.acknowledgeDrained();
    try testing.expectEqual(@as(usize, 1), receipts.len);
    try testing.expectEqual(@as(u64, 7), receipts[0]);
    try testing.expect(!r.historyRetained(7));
    try testing.expectEqual(@as(usize, 0), r.historyPending().len);
    try testing.expectEqual(@as(usize, 0), r.historyBytes());

    // Acknowledging again is a contract violation, not a second receipt.
    try testing.expectError(error.UnknownHistoryId, r.acknowledgeHistory(7));
    // And the rows are never written twice.
    try r.append(.{ .line = "after" });
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "one\r\n"));
}

test "region: a duplicate history id never appends twice" {
    var r = try makeRegion(1, .{});
    defer r.deinit();
    try r.writeHistory(.{ .id = 1, .rows = &.{"first"}, .kind = .append });
    // Still pending, and already written: both are duplicates.
    try testing.expectError(
        error.DuplicateHistoryId,
        r.writeHistory(.{ .id = 1, .rows = &.{"again"}, .kind = .append }),
    );

    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    try testing.expectEqual(@as(usize, 1), count(t1.bytes(), "first\r\n"));
    try testing.expectEqual(@as(usize, 0), count(t1.bytes(), "again\r\n"));
    try testing.expectError(
        error.DuplicateHistoryId,
        r.writeHistory(.{ .id = 1, .rows = &.{"third"}, .kind = .append }),
    );
    try testing.expectError(
        error.DuplicateHistoryId,
        r.writeHistory(.{ .id = 0, .rows = &.{"zero"}, .kind = .append }),
    );
    // A monotonic id is accepted.
    try r.writeHistory(.{ .id = 2, .rows = &.{"second"}, .kind = .append });
    try testing.expectEqual(@as(u64, 2), r.historyWatermark());
}

test "region: a batch is copied, so the caller may reuse its staging memory" {
    var r = try makeRegion(1, .{});
    defer r.deinit();
    var ab = "ab".*;
    var cd = "cd".*;
    var caller = [2][]u8{ &ab, &cd };
    try r.writeHistory(.{ .id = 1, .rows = caller[0..], .kind = .append });
    ab[0] = 'X';
    cd[0] = 'X';

    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    try testing.expect(std.mem.indexOf(u8, t.bytes(), "ab\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, t.bytes(), "cd\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, t.bytes(), "X") == null);
}

test "region: a replay reproduces the entire ledger in one write" {
    var r = try makeRegion(1, .{});
    defer r.deinit();
    try r.writeHistory(.{ .id = 1, .rows = &.{ "one", "two" }, .kind = .append });

    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    try testing.expectEqual(@as(usize, 1), count(t1.bytes(), "one\r\n"));
    _ = r.acknowledgeDrained();

    // The product replays the whole ledger: the rows appear again, in
    // order, in one contiguous write above the band.
    try r.writeHistory(.{ .id = 2, .rows = &.{ "one", "two" }, .kind = .replay });
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    const at = std.mem.indexOf(u8, t2.bytes(), "one\r\n").?;
    try testing.expectEqualStrings("one\r\ntwo\r\n", t2.bytes()[at..][0..10]);
    try testing.expectEqual(@as(usize, 1), count(t2.bytes(), "two\r\n"));
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "\x1b[2J"));
    const receipts = r.acknowledgeDrained();
    try testing.expectEqual(@as(usize, 1), receipts.len);
    try testing.expectEqual(@as(u64, 2), receipts[0]);
}

test "region: a replay supersedes batches and appends staged but unwritten" {
    var r = try makeRegion(1, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "a");
    try r.append(.{ .line = "queued" });
    try r.writeHistory(.{ .id = 1, .rows = &.{"stale"}, .kind = .append });
    try r.writeHistory(.{ .id = 2, .rows = &.{"fresh"}, .kind = .replay });

    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    // The replay restates the whole logical ledger, so it is the ONLY
    // thing on the wire: neither the stale batch nor the queued append
    // precedes it.
    try testing.expectEqualStrings(
        sync_on ++ hide_c ++ aw_off ++ cpr_q ++ "fresh\r\n" ++ "\ra\r" ++ aw_on ++ sync_off,
        t.bytes(),
    );
    // The superseded batch is gone; the replay is the whole ledger now.
    try testing.expect(!r.historyRetained(1));
    try testing.expect(r.historyRetained(2));
    try testing.expectEqual(@as(usize, 0), r.append_queue.items.len);
}

test "region: a replay that overflows the queue keeps the whole ledger for the retry" {
    // A replay supersedes work, so the supersession must be a COMMIT
    // effect: a queue that fills up part-way through the replay bytes
    // may not have destroyed anything yet. Otherwise the rows the
    // terminal never received are gone with no error path.
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try fillBand(&r.cur, "ab");

    // A written, unacknowledged batch the replay must NOT touch: its
    // bytes already reached the wire and its receipt is still owed.
    var t0: TestWriter = .{};
    t0.init();
    try r.render(&t0.w);
    try r.writeHistory(.{ .id = 1, .rows = &.{"settled"}, .kind = .append });
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    try testing.expectEqual(@as(usize, 1), r.history_written);

    try r.append(.{ .line = "queued" });
    try r.writeHistory(.{ .id = 2, .rows = &.{"superseded"}, .kind = .append });
    try r.writeHistory(.{ .id = 3, .rows = &.{ "ledger-a", "ledger-b" }, .kind = .replay });
    try r.writeHistory(.{ .id = 4, .rows = &.{"later"}, .kind = .append });

    // The envelope, the band-top move and the first replay row fit; the
    // second does not, so the frame dies mid-replay.
    var q = try output.OutputQueue.init(testing.allocator, .{ .capacity = 36, .watermark = 20 });
    defer q.deinit();
    q.beginFrame();
    try testing.expectError(error.WriteFailed, r.render(q.writer()));
    try testing.expect(q.frameOverflowed());
    q.abortFrame();
    try testing.expectEqual(@as(usize, 0), q.pending());

    // Nothing was superseded: the append queue, the written batch and
    // every unwritten batch are exactly as they were.
    try testing.expectEqual(@as(usize, 1), r.append_queue.items.len);
    try testing.expectEqual(@as(usize, 1), r.history_written);
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4 }, r.historyPending());

    // The retry delivers the complete replay exactly once, and only the
    // replay: the append and the other unwritten batches are superseded
    // NOW, on success.
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try testing.expectEqual(@as(usize, 1), count(t2.bytes(), "ledger-a\r\n"));
    try testing.expectEqual(@as(usize, 1), count(t2.bytes(), "ledger-b\r\n"));
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "settled"));
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "queued"));
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "superseded"));
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "later"));
    // The written batch is preserved; the replay replaced the rest.
    try testing.expect(r.historyRetained(1));
    try testing.expect(!r.historyRetained(2));
    try testing.expect(r.historyRetained(3));
    try testing.expect(!r.historyRetained(4));
    try testing.expectEqualSlices(u64, &.{ 1, 3 }, r.historyPending());
    try testing.expectEqual(@as(usize, 0), r.append_queue.items.len);
    // One drain acknowledges exactly the written batches: the settled
    // one from the earlier frame and the replay.
    try testing.expectEqualSlices(u64, &.{ 1, 3 }, r.acknowledgeDrained());
    try testing.expectEqual(@as(usize, 0), r.historyPending().len);
    try testing.expectEqual(@as(usize, 0), r.historyBytes());
}

test "region: a piped replay supersedes the queued appends" {
    // A pipe is the same contract without a cursor: the replay alone
    // reaches the stream.
    var r = try makeRegion(1, .{ .interactive = false });
    defer r.deinit();
    try r.resize(4, 1);
    try r.append(.{ .line = "queued" });
    try r.writeHistory(.{ .id = 1, .rows = &.{"stale"}, .kind = .append });
    try r.writeHistory(.{ .id = 2, .rows = &.{ "one", "two" }, .kind = .replay });
    try drawRow(&r.cur, 0, "band");

    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    try testing.expectEqualStrings("one\ntwo\nband\n", t.bytes());
}

test "region: a ledger write failure leaves the batch unwritten" {
    // A writer that fails before the ledger bytes: the batch stays in
    // the queue and the frame is retried whole.
    var r = try makeRegion(1, .{});
    defer r.deinit();
    try r.writeHistory(.{ .id = 1, .rows = &.{"rows"}, .kind = .append });

    var q = try output.OutputQueue.init(testing.allocator, .{ .capacity = 40, .watermark = 32 });
    defer q.deinit();
    q.beginFrame();
    try testing.expectError(error.WriteFailed, r.render(q.writer()));
    q.abortFrame();
    try testing.expectEqual(@as(usize, 0), r.history_written);
    try testing.expect(r.historyRetained(1));

    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    try testing.expectEqual(@as(usize, 1), count(t.bytes(), "rows\r\n"));
    try testing.expectEqual(@as(usize, 1), r.history_written);
}

test "region: retained ledger bytes are bounded and refused, never dropped" {
    var r = try makeRegion(1, .{ .max_history = 16 });
    defer r.deinit();
    // Rows plus their terminators: 11 + 4 = 15 of the 16-byte bound.
    try r.writeHistory(.{ .id = 1, .rows = &.{ "0123456789", "abc" }, .kind = .append });
    // The next batch would exceed the bound: refused, not truncated.
    try testing.expectError(
        error.HistoryTooLarge,
        r.writeHistory(.{ .id = 2, .rows = &.{"x"}, .kind = .append }),
    );
    try testing.expectEqual(@as(usize, 15), r.historyBytes());
    try testing.expectEqual(@as(u64, 1), r.historyWatermark());
    try testing.expect(r.historyRetained(1));
    try testing.expect(!r.historyRetained(2));

    // An unwritten batch is never acknowledged, so the bound still
    // holds: the refusal is the bound, not the acknowledgement order.
    _ = r.acknowledgeDrained();
    try testing.expectError(
        error.HistoryTooLarge,
        r.writeHistory(.{ .id = 2, .rows = &.{"x"}, .kind = .append }),
    );

    // Written and drained: the rows are gone, so the bound frees up.
    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    _ = r.acknowledgeDrained();
    try testing.expectEqual(@as(usize, 0), r.historyBytes());
    try r.writeHistory(.{ .id = 3, .rows = &.{"y"}, .kind = .append });
    try testing.expect(r.historyRetained(3));
}

test "region: writeTranscript stages one batch with a Region-owned receipt" {
    var r = try makeRegion(1, .{});
    defer r.deinit();
    const first = try r.writeTranscript(&.{"a"});
    const second = try r.writeTranscript(&.{ "b", "c" });
    try testing.expectEqual(@as(u64, 1), first);
    try testing.expectEqual(@as(u64, 2), second);

    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    try testing.expectEqual(@as(usize, 1), count(t.bytes(), "a\r\n"));
    try testing.expectEqual(@as(usize, 1), count(t.bytes(), "c\r\n"));
    const receipts = r.acknowledgeDrained();
    try testing.expectEqualSlices(u64, &.{ 1, 2 }, receipts);
}

// ── C2: resize modes ──────────────────────────────────

test "region: resize append clears from the anchor and repaints in place" {
    var r = try makeRegion(3, .{ .mode = .append });
    defer r.deinit();
    try r.resize(10, 3);
    try fillBand(&r.cur, "abc");

    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    try testing.expectEqual(@as(u16, 0), r.anchor_row);

    try r.resize(40, 3);
    try clearRow(&r.cur, 0, 40);
    try clearRow(&r.cur, 1, 40);
    try clearRow(&r.cur, 2, 40);
    try fillBand(&r.cur, "abc");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try testing.expectEqualStrings(
        sync_on ++ aw_off ++ cpr_q ++ "\r\x1b[2A\x1b[J\r\x1b[Kabc\r\n\x1b[Kabc\r\n\x1b[Kabc\r" ++
            aw_on ++ sync_off,
        t2.bytes(),
    );
    // The anchor did not move: the band stayed where it was.
    try testing.expectEqual(@as(u16, 0), r.anchor_row);
    try testing.expect(!r.width_dirty);
}

test "region: resize rebuild repaints downward and leaves the old extent painted" {
    var r = try makeRegion(3, .{ .mode = .rebuild });
    defer r.deinit();
    try r.resize(10, 3);
    try fillBand(&r.cur, "abc");

    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    try r.resize(40, 3);
    try clearRow(&r.cur, 0, 40);
    try clearRow(&r.cur, 1, 40);
    try clearRow(&r.cur, 2, 40);
    try fillBand(&r.cur, "xyz");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    // No ED0: the rows above the band are never touched. The cursor
    // parks on the last row it painted — the band bottom — with no
    // extra walk down past it.
    try testing.expectEqualStrings(
        sync_on ++ aw_off ++ cpr_q ++ "\r\x1b[Kxyz\r\n\x1b[Kxyz\r\n\x1b[Kxyz\r" ++ aw_on ++ sync_off,
        t2.bytes(),
    );
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "\x1b[J"));
}

test "region: resize rebuild on a shorter band leaves the extra rows settled" {
    var r = try makeRegion(3, .{ .mode = .rebuild });
    defer r.deinit();
    try r.resize(10, 3);
    try fillBand(&r.cur, "abc");
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    const before = r.anchor_row;

    // A width change together with a shorter band: `.rebuild` re-anchors
    // at the live bottom and repaints downward. The band top moves to
    // the old bottom (row 2), so the band now owns rows 2 and 3 and
    // rows 0 and 1 stay on screen as settled content.
    try r.resize(20, 2);
    try clearRow(&r.cur, 0, 20);
    try clearRow(&r.cur, 1, 20);
    try drawRow(&r.cur, 0, "one");
    try drawRow(&r.cur, 1, "two");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    // The band top moved down by `painted - 1` rows, and the anchor
    // follows it until the CPR reply confirms the new top.
    try testing.expectEqual(before + 2, r.anchor_row);
    try testing.expectEqual(@as(u16, 2), r.painted_rows);
    // The deliberate bottom re-anchor re-queried in this very frame.
    try testing.expectEqual(@as(usize, 1), count(t2.bytes(), cpr_q));

    var term: Term = .{};
    term.feed(t1.bytes());
    term.feed(t2.bytes());
    try testing.expectEqualStrings("one", term.text(2));
    try testing.expectEqualStrings("two", term.text(3));
    // The rows the shorter band released stay exactly as they were.
    try testing.expectEqualStrings("abc", term.text(0));
    try testing.expectEqualStrings("abc", term.text(1));
    // The cursor parked on the new band bottom — the row the next
    // frame's relative moves start from.
    try testing.expectEqual(@as(usize, 3), term.row);
    // A real terminal answers from the parked cursor (1-indexed); the
    // reply must re-anchor exactly onto the new band top.
    try r.applyCpr(@intCast(term.row + 1), 1);
    try testing.expectEqual(@as(u16, 3), r.anchor_row);
    try testing.expect(!r.anchor_dirty);

    // The FOLLOWING frame is the proof: a diff must land on the rows
    // the new band owns. An extra painted-height newline would park the
    // cursor one row low and push this paint to row 4.
    try clearRow(&r.cur, 1, 20);
    try drawRow(&r.cur, 1, "TWO");
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    term.feed(t3.bytes());
    try testing.expectEqualStrings("one", term.text(2));
    try testing.expectEqualStrings("TWO", term.text(3));
    try testing.expectEqualStrings("", term.text(4));
    try testing.expectEqual(@as(usize, 3), term.row);
    // A rebuild is row-scoped: no ED0 and no alt screen anywhere.
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "\x1b[J"));
    try testing.expectEqual(@as(usize, 0), count(t3.bytes(), "\x1b[J"));
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "\x1b[?1049"));
    try testing.expectEqual(@as(usize, 0), count(t3.bytes(), "\x1b[?1049"));
}

test "region: resize preserve reflows row-scoped, never clearing the band" {
    var r = try makeRegion(3, .{ .mode = .preserve });
    defer r.deinit();
    try r.resize(10, 3);
    try fillBand(&r.cur, "abc");
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    // The app re-lays out settled rows for the new width: only row 1
    // changes, and it is erased and repainted at its own band row.
    try r.resize(40, 3);
    try clearRow(&r.cur, 1, 40);
    try drawRow(&r.cur, 1, "reflowed");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try testing.expectEqualStrings(
        sync_on ++ aw_off ++ cpr_q ++ "\r\x1b[2A\r\n\x1b[Kreflowed\r\n" ++ aw_on ++ sync_off,
        t2.bytes(),
    );
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "\x1b[J"));
    // Row 0 kept its old content: a preserve reflow never clears the
    // band, so untouched rows are not even visited.
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "abc"));
    try testing.expectEqual(@as(u16, 0), r.anchor_row);
}

test "region: a mid-stream resize does not duplicate the transcript" {
    var r = try makeRegion(2, .{ .mode = .append });
    defer r.deinit();
    try r.resize(10, 2);
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    try r.writeHistory(.{ .id = 1, .rows = &.{"committed"}, .kind = .append });

    var stream: std.ArrayListUnmanaged(u8) = .empty;
    defer stream.deinit(testing.allocator);
    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    try stream.appendSlice(testing.allocator, t.bytes());
    _ = r.acknowledgeDrained();

    for ([_]u16{ 20, 30, 10 }) |w| {
        try r.resize(w, 2);
        t.init();
        try r.render(&t.w);
        try stream.appendSlice(testing.allocator, t.bytes());
    }
    // The committed row appears exactly once across the whole session,
    // no matter how the width moved.
    try testing.expectEqual(@as(usize, 1), count(stream.items, "committed\r\n"));
    try testing.expectEqual(@as(usize, 0), count(stream.items, "\x1b[2J"));
    try testing.expectEqual(@as(usize, 0), count(stream.items, "\x1b[3J"));
}

// ── anchor + CPR ──────────────────────────────────────

test "region: CPR on the first render and after a resize, never in steady state" {
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    try testing.expect(std.mem.indexOf(u8, t1.bytes(), cpr_q) != null);

    try clearRow(&r.cur, 0, 2);
    try drawRow(&r.cur, 0, "aa");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try testing.expect(std.mem.indexOf(u8, t2.bytes(), cpr_q) == null);

    try clearRow(&r.cur, 1, 2);
    try drawRow(&r.cur, 1, "dd");
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    try testing.expect(std.mem.indexOf(u8, t3.bytes(), cpr_q) == null);

    try r.resize(30, 2);
    var t4: TestWriter = .{};
    t4.init();
    try r.render(&t4.w);
    try testing.expect(std.mem.indexOf(u8, t4.bytes(), cpr_q) != null);
}

test "region: reanchor re-queries on the next render" {
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try testing.expectEqualStrings("", t2.bytes());

    try r.reanchor();
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    // An idle frame with a pending re-anchor emits the envelope and the
    // query only, and parks back at the band bottom.
    try testing.expectEqualStrings(framed(cpr_q ++ "\r"), t3.bytes());
}

test "region: applyCpr corrects the anchor from the parked band bottom" {
    var r = try makeRegion(3, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "aaa");
    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    // Cursor parked at the band bottom, 1-indexed row 12: the band top
    // is height - 1 rows above it, 12 - 2 = 10.
    try r.applyCpr(12, 1);
    try testing.expectEqual(@as(u16, 10), r.anchor_row);
    try testing.expect(!r.anchor_dirty);

    // A reply above the band height saturates to 0.
    try r.applyCpr(1, 1);
    try testing.expectEqual(@as(u16, 0), r.anchor_row);
    // A single-row band anchors exactly at the reply row.
    var r1 = try makeRegion(1, .{});
    defer r1.deinit();
    try drawRow(&r1.cur, 0, "a");
    var t1: TestWriter = .{};
    t1.init();
    try r1.render(&t1.w);
    try r1.applyCpr(7, 1);
    try testing.expectEqual(@as(u16, 7), r1.anchor_row);
}

test "region: applyFirstCpr re-anchors from the tracked shifts" {
    // The FIRST reply answers the query emitted before the first paint,
    // when the cursor sat at the pre-frame row R; the bookkeeping then
    // holds every shift applied on top of R (the CNL reservation, a
    // ledger write, height deltas).
    var r = try makeRegion(3, .{ .append_lines = true });
    defer r.deinit();
    try drawRow(&r.cur, 0, "aaa");
    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    // The CNL reservation is already tracked: `anchor_row` holds the
    // three rows the first frame shifted the band down, and the reply
    // supplies the pre-frame row the shift is measured from.
    try testing.expectEqual(@as(u16, 3), r.anchorRow());
    r.applyFirstCpr(4);
    try testing.expectEqual(@as(u16, 7), r.anchorRow());

    // Without append_lines the band was painted from the cursor: no
    // tracked shift, the reply row IS the band top.
    var r2 = try makeRegion(3, .{});
    defer r2.deinit();
    try drawRow(&r2.cur, 0, "aaa");
    var t2: TestWriter = .{};
    t2.init();
    try r2.render(&t2.w);
    r2.applyFirstCpr(4);
    try testing.expectEqual(@as(u16, 4), r2.anchorRow());
}

test "region: anchorRow exposes the tracked band top" {
    var r = try makeRegion(3, .{});
    defer r.deinit();
    try testing.expectEqual(@as(u16, 0), r.anchorRow());
    r.anchor_row = 10;
    try testing.expectEqual(@as(u16, 10), r.anchorRow());
}

test "region: placeAt CUP's to the cell and parks at the painted band bottom" {
    var r = try makeRegion(3, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "aaa");
    var t0: TestWriter = .{};
    t0.init();
    try r.render(&t0.w);
    r.anchor_row = 5;

    var t: TestWriter = .{};
    t.init();
    try r.placeAt(&t.w, 1, 2, .{ .id = 1 });
    try testing.expectEqualStrings(
        "\x1b[6;2H\x1b_Ga=p,q=1,i=1\x1b\\\x1b[7;1H",
        t.bytes(),
    );
}

test "region: a wide glyph row diff never emits the continuation" {
    var r = try makeRegion(1, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "a👨‍🌾b");
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    try testing.expectEqualStrings(
        sync_on ++ hide_c ++ aw_off ++ cpr_q ++ "\ra👨‍🌾b\r" ++ aw_on ++ sync_off,
        t1.bytes(),
    );

    try clearRow(&r.cur, 0, 5);
    try drawRow(&r.cur, 0, "a👨‍🌾c");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try testing.expectEqualStrings(framed("\r\r\x1b[Ka👨‍🌾c\r"), t2.bytes());
}

// ── previous-content ownership (the diff's soundness base) ──

test "region: prev owns the previous content, not the app's staging bytes" {
    var r = try makeRegion(2, .{});
    defer r.deinit();

    // The app paints from a buffer it rewrites IN PLACE at the same
    // length — a counter, a percentage, an editor line. A shallow copy
    // of the cell slices would make `prev` change with it, the damage
    // test would call the row unchanged, and nothing would repaint.
    var text: [3]u8 = "abc".*;
    _ = try r.cur.draw(Style{}, &text, 0, 0);
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    try testing.expectEqualStrings(
        sync_on ++ hide_c ++ aw_off ++ cpr_q ++ "\rabc\r\n\r" ++ aw_on ++ sync_off,
        t1.bytes(),
    );

    text = "xyz".*;
    _ = try r.cur.draw(Style{}, &text, 0, 0);
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    // Row 0 is real damage and is repainted from the anchor; the stale
    // blank tail below it is erased row-scoped.
    try testing.expectEqual(@as(usize, 1), count(t2.bytes(), "xyz"));
    try testing.expect(std.mem.indexOf(u8, t2.bytes(), "abc") == null);
    try testing.expect(std.mem.indexOf(u8, t2.bytes(), "\r\x1b[1A\r\x1b[Kxyz") != null);
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "\x1b[J"));

    // And the same in place again: still damage, still emitted.
    text = "012".*;
    _ = try r.cur.draw(Style{}, &text, 0, 0);
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    try testing.expectEqual(@as(usize, 1), count(t3.bytes(), "012"));
    try testing.expect(std.mem.indexOf(u8, t3.bytes(), "xyz") == null);
}

test "region: a reallocated staging buffer leaves the snapshot intact" {
    var r = try makeRegion(1, .{});
    defer r.deinit();

    // Two different allocations with the same content: the app's buffer
    // moved, the content did not. A borrowed snapshot would either see
    // the new address (noise) or dangle when the old one is freed.
    const first = try testing.allocator.dupe(u8, "same");
    defer testing.allocator.free(first);
    _ = try r.cur.draw(Style{}, first, 0, 0);
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    const second = try testing.allocator.dupe(u8, "same");
    defer testing.allocator.free(second);
    _ = try r.cur.draw(Style{}, second, 0, 0);
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    // Unchanged content: no repaint, even though the app's slice moved.
    try testing.expectEqualStrings("", t2.bytes());

    // Freeing the app's buffer does not dangle the snapshot: different
    // content in the same slot still counts as damage.
    const third = try testing.allocator.dupe(u8, "diff");
    defer testing.allocator.free(third);
    _ = try r.cur.draw(Style{}, third, 0, 0);
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    try testing.expectEqual(@as(usize, 1), count(t3.bytes(), "diff"));
    try testing.expect(std.mem.indexOf(u8, t3.bytes(), "\r\x1b[Kdiff") != null);
    try testing.expectEqual(@as(usize, 0), count(t3.bytes(), "same"));
}

/// A counting allocator: proves the steady state allocates NOTHING per
/// frame, instead of inferring it from arena capacity.
const CountAlloc = struct {
    inner: std.mem.Allocator,
    allocs: usize = 0,

    fn allocator(self: *CountAlloc) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountAlloc = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        return self.inner.rawAlloc(len, alignment, ret_addr);
    }
    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountAlloc = @ptrCast(@alignCast(ctx));
        return self.inner.rawResize(memory, alignment, new_len, ret_addr);
    }
    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountAlloc = @ptrCast(@alignCast(ctx));
        return self.inner.rawRemap(memory, alignment, new_len, ret_addr);
    }
    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountAlloc = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(memory, alignment, ret_addr);
    }
};

test "region: a steady frame allocates nothing — the snapshot reuses its storage" {
    var counter: CountAlloc = .{ .inner = testing.allocator };
    var r = try Region.init(counter.allocator(), .{
        .height = 2,
        .interactive = true,
        .sync_output = true,
    });
    defer r.deinit();
    var text: [4]u8 = "aaaa".*;
    var t: TestWriter = .{};

    // Warm up with REAL frames: an identical redraw early-returns, and
    // the first rendered frame only warms the arena it prepared in. Both
    // snapshot arenas (the live one and the scratch the next frame builds
    // in) and the per-cell slice list have to reach their high-water
    // mark before the steady state means anything.
    for (0..4) |i| {
        text[0] = @intCast('a' + (i % 6));
        t.init();
        _ = try r.cur.draw(Style{}, &text, 0, 0);
        try r.render(&t.w);
    }
    const warm = counter.allocs;
    try testing.expect(warm > 0); // the warmup really did allocate

    // Steady state with real churn: zero allocations across the whole
    // loop, measured — not inferred from an unchanged capacity.
    for (0..32) |i| {
        text[0] = @intCast('a' + (i % 6));
        t.init();
        _ = try r.cur.draw(Style{}, &text, 0, 0);
        try r.render(&t.w);
    }
    try testing.expectEqual(warm, counter.allocs);
    // The snapshot OWNS the last frame's text: rewriting the app's
    // buffer in place after the commit is still real damage, so `prev`
    // never aliases the caller's bytes.
    text[0] = 'z';
    try testing.expect(r.dirtyCells() > 0);
}

test "region: a batch that has not been written yet cannot be acknowledged" {
    var r = try makeRegion(1, .{});
    defer r.deinit();
    try r.writeHistory(.{ .id = 1, .rows = &.{"pending"}, .kind = .append });

    // Staged, never written: the terminal has not seen these rows, so
    // acknowledging would release history that was never delivered.
    try testing.expectError(error.UnknownHistoryId, r.acknowledgeHistory(1));
    try testing.expect(r.historyRetained(1));

    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    // Written now, so the product may acknowledge before the transport
    // drain reports it.
    try r.acknowledgeHistory(1);
    try testing.expect(!r.historyRetained(1));
    try testing.expectEqual(@as(usize, 0), r.historyPending().len);
    try testing.expectEqual(@as(usize, 1), count(t.bytes(), "pending\r\n"));
    // The written cursor is consistent again, so a later drain cannot
    // walk past the end of the list.
    try testing.expectEqual(@as(usize, 0), r.history_written);
    _ = r.acknowledgeDrained();
    try testing.expectEqual(@as(usize, 0), r.history_written);
}

test "region: acknowledging out of write order never releases an unwritten batch" {
    var r = try makeRegion(1, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "b");
    try r.writeHistory(.{ .id = 1, .rows = &.{"one"}, .kind = .append });
    try r.writeHistory(.{ .id = 2, .rows = &.{"two"}, .kind = .append });
    try r.writeHistory(.{ .id = 3, .rows = &.{"three"}, .kind = .append });

    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    try testing.expectEqual(@as(usize, 3), r.history_written);

    // The product acknowledges the middle batch first. Its rows stay
    // owned until the written batches in front of it are acknowledged
    // too — releasing it here would slide an unwritten batch into the
    // written range.
    try r.acknowledgeHistory(2);
    try testing.expect(r.historyRetained(2));

    try r.writeHistory(.{ .id = 4, .rows = &.{"later"}, .kind = .append });
    const receipts = r.acknowledgeDrained();
    try testing.expectEqualSlices(u64, &.{ 1, 3 }, receipts);
    try testing.expect(r.historyRetained(4));
    try testing.expectEqual(@as(usize, 0), r.history_written);

    // The next frame writes the batch the drain did not acknowledge:
    // the written range never skipped it.
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try testing.expectEqual(@as(usize, 1), count(t2.bytes(), "later\r\n"));
    try testing.expectEqualSlices(u64, &.{4}, r.acknowledgeDrained());
    try testing.expect(!r.historyRetained(4));
}
