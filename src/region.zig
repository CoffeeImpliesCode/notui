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
//!   autowrap on (DECAWM) → frame → sync end → show cursor (on the
//!   hidden→visible transition). Every row write allows a frame arriving
//!   after a width change to soft-wrap rather than lose text. CR clears
//!   a deferred wrap when the widths match. `interactive` gates the whole
//!   envelope; `sync_output` only gates the 2026 pair. Idle emits ZERO bytes.
//!   `exit()` (and the panic path in tty.zig) restores autowrap, the
//!   cursor and the sync state.
//!
//! - **Transactional frames.** `render` stages the whole frame into the
//!   writer and commits the region state — `prev`, the dirty flags, the
//!   append queue, the ledger receipts, the anchor — only after the last
//!   byte is staged. Failure preserves the committed snapshot and queued payloads,
//!   though reusable capacity and preparation state may change. Discard a failed
//!   staging prefix before retrying; a direct terminal writer needs explicit recovery.
//!
//! - **Anchor.** The band top is the anchor; between frames the cursor
//!   sits at the band bottom (column 1 of the last row) and every move
//!   is relative (`\r` + CUU / LF / ED). No absolute CUP is emitted
//!   except `placeAt`, which restores the parked cursor. The absolute
//!   row is a MEASUREMENT: `anchorRow()` is 0 until a Cursor Position
//!   Report has answered the region's own `ESC[6n`, and 0 again the
//!   moment a column or physical-height change invalidates it.
//!   Between those points the tracked shifts carry it.
//!
//! - **CPR protocol.** `ESC[6n` is emitted AFTER the frame has painted
//!   and parked, still inside the envelope, and at most ONE query is
//!   ever outstanding: the reply is untagged, so a second query would
//!   make two answers indistinguishable. The query records the
//!   geometry generation it was asked under, and every frame that
//!   commits while it waits contributes its ordered, clamped cursor
//!   walk, so a reply that lands late is transformed onto the cursor
//!   the region is at now instead of being read as if nothing had
//!   moved. A reply that arrives unsolicited (nothing outstanding), or
//!   after the generation moved, is discarded and never touches the
//!   anchor; the slot is held until that reply is consumed or
//!   discarded and the next frame asks once more. An idle frame stays
//!   silent while a query waits: the Region depends on the host
//!   delivering `Event.cpr`, and re-asking every tick would flood a
//!   terminal that answers late.
//!
//! - **Viewport height.** `resize` takes the terminal's VISIBLE rows
//!   beside the logical band height the app wants; the two are
//!   different facts. A window dragged shorter keeps the cursor's line:
//!   what it takes is the rows above that line that no longer fit (they
//!   become scrollback) plus the tail under it (those simply are not
//!   there any more), so a band parked mid-window keeps the row it is on
//!   and a row the band owns can leave the screen while `prev` still
//!   holds its text — and a diff would never write it again. A physical
//!   height change is therefore tracked apart from `setHeight` (logical
//!   only): the next frame re-bases the band on the cursor, erases
//!   row-scoped the rows it still owns and gives up, and repaints ALL of
//!   them. The surviving extent is bounded by the viewport and, when
//!   measured, the rows through the cursor. A clipped width change asks
//!   CPR before repainting, so a cursor above the bottom loses no prefix.
//!
//!   The other side of the same fact: a band whose physical extent is
//!   PAST the window has its top on the window's first row, and no row
//!   above that for a queued `.line`, `.text` or history batch to be
//!   written on. Such a flush cannot run — `.physical` outranks it and
//!   repaints the band without writing anything, and `.ledger`, the
//!   only frame that could, is unreachable. The queue is therefore not
//!   dropped and not faked: an idle frame stays silent rather than
//!   repaint the band and strand another copy of it, and the first
//!   frame whose top is reachable again writes the whole queue, in
//!   order.
//!
//! - **Retired rows.** A physical clip can leave band rows above the
//!   re-based top: the band gave them up, nothing committed them, and a
//!   taller window hands them straight back on the screen when it pulls
//!   its scrollback in — the live popup would then read twice. Those
//!   rows are RETIRED, tracked as runs of offsets above the current band
//!   top. Once CPR measures their visibility, a contiguous retired prefix
//!   is reclaimed by repainting the band upward over it and erasing the
//!   unused old bottom. Distant retired rows are erased in place with EL.
//!   Committed history is never retired, reclaimed or erased with them:
//!   a ledger write, a `.line`, a `.text` or a `.rebuild` row
//!   only SHIFTS the offsets past it. Newlines are emitted as hard CRLF
//!   moves; the declared native model projects any arrival-time soft wraps
//!   when the changed width is observed. A growth that appends empty rows
//!   below the cursor reveals nothing at all, so a run the viewport cannot
//!   reach stays tracked rather than assumed gone.
//!
//!   What bounds the erase is `reach`, the number of rows above the band
//!   top the viewport can be showing. It is DERIVED, not accumulated:
//!   the cursor's screen row less the band's own extent, with the cursor
//!   row walked one move at a time, in the order the bytes go out, and
//!   clamped at both edges of the viewport. That is what keeps the walk
//!   from asking for a row the screen does not have — a CUU past the
//!   viewport top clamps onto the window's first row and blanks whatever
//!   is on it, and that row is committed history.
//!
//! - **Erase discipline (B3).** No screen-wide erase: the renderer
//!   never emits ED2 (`ESC[2J`) or ED3 (`ESC[3J`), so tmux and
//!   conhost scrollback above the band is never destroyed. Every erase
//!   is either row-scoped (EL, `ESC[K`) or ED0 (`ESC[J`) from the band
//!   anchor downward — the rows the band owns and nothing above it.
//!   Committed history is never erased. Strategy-by-strategy bytes:
//!   `first` (no erase), `ledger` (ED0 at the anchor), `resize` (ED0 at
//!   the anchor in `append`, per-row EL in `rebuild` and `preserve`,
//!   plus the release or reservation of a height change arriving with
//!   it), `height` (no erase; a CRLF reservation for the rows the band
//!   gained, per-row EL for the tail it lost), `diff` (per-row EL for
//!   the high-water tail), `physical` (per-row EL from the topmost row
//!   the old extent can still reach, then a full repaint), `collapse`
//!   (no erase — the band is released, not erased). The band extent the
//!   CURRENT frame settles — the painted one for a steady diff, the
//!   reserved or kept one for a height change — drives every cursor
//!   move; never a `new - old` delta, and never the extent a single
//!   height call asked for: a run of `setHeight`/`resize` calls between
//!   two frames settles once, on the difference from the extent already
//!   on screen.
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
//! - **Native width reflow.** `Options.terminal_reflow` is a
//!   DECLARATION, never a probe: nothing here reads `TERM`, the
//!   environment or the terminal's identity. The default is
//!   `TerminalReflow.rewrapping`, because xterm.js, VTE, kitty, iTerm2,
//!   WezTerm, foot and tmux all rewrap old rows on a width change.
//!   `.none` is the model for a terminal that never rewraps (classic
//!   xterm) — a width change leaves every physical row where it was.
//!   `.non_cursor_rows` declares an xterm-style terminal that repacks
//!   every hard logical group on a width change EXCEPT the group the
//!   cursor is in (narrowing and widening alike), and carries the
//!   exact scrollback retention the caller configured, so a row the
//!   terminal dropped irreversibly from the front of its buffer is
//!   never later mistaken for one it merely hid.
//!
//!   Under that declaration a width change changes the band's physical
//!   extent, so the renderer keeps the EMITTED GEOMETRY of everything
//!   it owns — one `Buffer.RowFootprint` per hard logical group, with
//!   the width-2 glyph positions on one reused tape — instead of the
//!   assumed extent. The old extent is then a projection of that one
//!   ordered ledger, never `painted_rows`: rows the terminal pushed
//!   out of reach are RETIRED, rows the screen still shows are cleared
//!   row-scoped, and the band repaints the layout the app re-laid out.
//!   Committed rows keep their geometry after their text is
//!   acknowledged and freed, so a later widening can still project
//!   them; the rows the cursor's own group may clip away are never
//!   recorded as reflow geometry they no longer have.
//!
//! Writer-agnostic: imports only buffer, cell, style, emit, image
//! (kitty placement via `placeAt`), width and markdown (the one escape
//! machine caller text is measured through). No tty, no zg — the zg import
//! grep-gate is `width.zig` only.
//!
//! Use through `@import("notui").region`: `init`, `resize`, draw into `cur`, then
//! `render` into caller-owned staging. Call `exit` before one `deinit`.
//! This module does not own a terminal or drain the writer. Failed writes may have
//! emitted a prefix; discard failed staging before retrying, or restore the terminal.

const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Cell = @import("cell.zig").Cell;
const Style = @import("style.zig").Style;
const emit = @import("emit.zig");
const markdown = @import("markdown.zig");
const Width = @import("width.zig");
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
/// Construct with `init`; a literal is not an initialized owner. The stored `gpa` must
/// stay live through one `deinit`. Copies share storage, not independent ownership.
/// Use on one thread without reentry through a writer. Only `cur`'s cells are
/// caller-mutable; other reachable fields are read-only state owned by the renderer.
/// `cur` borrows drawn strings until rendering consumes them. `prev` owns grapheme
/// copies, but style hyperlink strings remain borrowed until that snapshot is replaced
/// by a successful render or `deinit`. Mutating those strings can hide style damage.
pub const Region = struct {
    /// What the CALLER's terminal does to hard logical groups when the
    /// window's width changes.
    ///
    /// A DECLARATION, never a probe: nothing here reads `TERM`, the
    /// environment or the terminal's identity, and there is no fallback
    /// that guesses one model from another. The default, `rewrapping`, is
    /// what nearly every current terminal does; a caller driving one that
    /// does not rewrap declares `.none`.
    ///
    /// Native packing follows measured non-corrupting xterm reflow: at least
    /// two columns, no split wide glyph, the whole current cursor group
    /// excluded on shrink and growth, and full-line erase ending a wrap.
    /// Source-preserving front eviction is also required; installed xterm
    /// can violate it during capped width overflow and is not supported there.
    pub const TerminalReflow = union(enum) {
        /// The terminal never rewraps rows on a width change (classic
        /// xterm): every band row keeps its place.
        none,
        /// Repack non-cursor hard groups on width change and retain exactly
        /// `scrollback_rows` rows above the viewport. Zero is valid.
        ///
        /// The band must be at the transcript tail. Rows below its parked
        /// cursor must be unused, unprinted hard blanks generated by the
        /// terminal, not rows left by cursor traversal, erasure or foreign
        /// writes. Native expansion consumes this padding before eviction.
        ///
        /// Eviction must remove only the oldest source chunks, preserving
        /// every later row. Installed xterm can overwrite later committed
        /// rows during capped width reflow; those sequences are outside this
        /// profile. Capacity and CPR cannot recover those corrupted bytes.
        ///
        /// Caller declaration only: no detection, probe, mode refusal or
        /// fallback. Unknown capacity uses `rewrapping`, whose unbounded
        /// retention only misplaces rows the terminal already evicted from
        /// the top of its scrollback. The caller must route CPR replies
        /// through `applyCpr`.
        non_cursor_rows: struct {
            /// Rows of scrollback the terminal retains above the
            /// visible screen before it discards the oldest row.
            scrollback_rows: u32,
        },

        /// The default: rewrap non-cursor groups, scrollback retention
        /// unknown and treated as unbounded.
        pub const rewrapping: TerminalReflow = .{
            .non_cursor_rows = .{ .scrollback_rows = std.math.maxInt(u32) },
        };
    };

    /// Band geometry and terminal behavior supplied at initialization.
    /// Defaults assume interactive relative-cursor rendering in a terminal
    /// that rewraps old rows on a width change.
    pub const Options = struct {
        /// Number of terminal rows the region owns.
        height: u16,
        /// Reserve the band on the FIRST render with `n` CRLFs,
        /// pushing the terminal so the region owns a stable band. Later
        /// height changes always reserve physically (a band that does
        /// not exist cannot be painted).
        append_lines: bool = true,
        /// Interactive terminal session: the paint envelope, cursor
        /// hiding, CPR re-queries, band reservation, the ledger and the
        /// exit park. False = piped/degraded output: one plain frame,
        /// no escape sequences, and `sync_output` is ignored.
        interactive: bool = true,
        /// Enables DEC 2026 around an interactive frame; default assumes support.
        /// Set false for terminals without synchronized output. Ignored when noninteractive.
        sync_output: bool = true,
        /// Resize behaviour for a width change.
        resize_mode: ResizeMode = .append,
        /// The caller's declared model for native width reflow. The default
        /// rewraps with unbounded retention; `.none` declares a terminal
        /// that never rewraps, and `.non_cursor_rows` with an exact
        /// `scrollback_rows` states the real retention. See `TerminalReflow`.
        terminal_reflow: TerminalReflow = .rewrapping,
        /// Hard bound on retained ledger bytes (copied rows waiting for
        /// a receipt). Exceeding it is `error.HistoryTooLarge`, never a
        /// silent drop.
        max_history_bytes: usize = 256 * 1024,
    };

    /// Queued scrollback output. Payload slices remain caller-owned and immutable
    /// until a successful flushing render or `deinit`; a screen-covering band can defer
    /// flushing indefinitely. Use `writeHistory` for an immediately copied payload.
    pub const Append = union(enum) {
        /// Free text; the terminal reflows/wraps it. Internal `\n` is
        /// written as `\r\n`, so every one of them is a HARD row move:
        /// the band top drops by exactly the number of newlines the item
        /// writes (plus the terminator it adds), and the region's own
        /// bookkeeping shifts by the same count. The row count itself is
        /// the caller's to keep right — the anchor is re-queried next
        /// frame — but the shift it applies to the tracked rows above
        /// the band is computed here, never left to the terminal.
        ///
        /// Caller contract: the text carries no cursor-control escapes
        /// (no CSI, no other C0 beyond the `\n`s it splits on). Nothing
        /// here inspects what it writes, so an escape that moves the
        /// cursor moves it off that count and off this region's
        /// bookkeeping with it. The region protects a `.line` or a
        /// `.text` that keeps to the contract; it does not defend
        /// against one that does not.
        text: []const u8,
        /// Plain text, hard-wrapped at flush time to `width` terminal cells
        /// under `Width.getMode`. Newlines start hard rows; a trailing newline
        /// already terminates the final row. Contains no other cursor controls.
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
        /// The terminal's visible height changed under a band that
        /// occupies more rows than the screen can reach: re-base it on
        /// the cursor and repaint every surviving row.
        physical,
        /// The band's height changed: reserve the rows it gained or
        /// erase the tail it lost, then diff. The step is the NET
        /// difference from the extent on screen, never one call's delta.
        height,
        /// `height` reached 0: release the band, erase nothing.
        collapse,
        /// Steady state: diff, then clear the high-water tail.
        diff,
    };
    /// The state one frame intends to change. Nothing here is applied
    /// until the frame is fully staged (transactional frames).
    const Frame = struct {
        /// The frame staged the postpaint CPR query; the slot is taken
        /// on commit, never before the bytes that answer it exist.
        query: bool = false,
        hide_cursor: bool = false,
        show_cursor: bool = false,
        /// Bookkeeping the frame applies on commit.
        high_water: u16 = 0,
        painted: u16 = 0,
        anchor_dirty: bool = false,
        clear_first: bool = false,
        /// The band was re-based and repainted after a physical height
        /// change; publishes `physical_dirty`.
        clear_physical: bool = false,
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
        /// Old band rows this frame moved OUT of the band and into the
        /// ownership ledger above it: a physical re-base retires the
        /// ones it can no longer reach and leaves the rest as hard
        /// blanks, a `.rebuild` settles them as committed history.
        ledger_out: ?LedgerOut = null,
        /// Hard blank rows inserted between the ledger's nearest group
        /// and the band top: a reservation's own rows, the gap a
        /// released tail leaves, or the gap between an erased suffix
        /// and the surviving prefix. Never erasable and never trimmed —
        /// they only have to be COUNTED, because every offset above the
        /// band top is a projection from the ledger rather than a
        /// stored number that could drift away from it.
        band_push: u32 = 0,
        /// Visible retired rows immediately above the old band top that
        /// this frame takes back into the band rather than leaving blank.
        reclaimed: u32 = 0,
        /// The transform from the row the outstanding CPR query was asked
        /// about to the row the cursor is on now: a shift plus the
        /// window of rows the walk can currently be at, `low`..`high`.
        ///
        /// A NET DELTA is not this. The reply names a row the Region does
        /// not know, so the only exact answer is the composition of the
        /// ordered, clamped moves themselves — and that composition
        /// collapses to exactly three numbers: append every move to
        /// `shift` and push `low` and `high` through the same boundary
        /// the real cursor was pushed through. A query row of 4 on a
        /// window where the walk went up ten and back down ten is 10, not
        /// 4, because the first ten rows clamped at the top.
        query_shift: i32 = 0,
        query_low: i32 = 0,
        query_high: i32 = 0,
        /// The cursor's row on the screen while THIS frame is composed,
        /// counted from the window's first visible row. It starts at the
        /// row the previous frame parked the cursor on and is moved by
        /// every cursor move this frame emits, IN THE ORDER the bytes go
        /// out — a CUU up (clamped at the window's first row), a newline
        /// or CUD down (clamped at its last row).
        ///
        /// Order is the whole point: a walk up that clamps against the
        /// viewport top starts the walk back down from where it stopped,
        /// so the sum of a frame's moves is not the row the frame ends
        /// on. A two-row band on the window's top row that grows to four
        /// walks up three rows to its own top AFTER reserving two, and
        /// parks three rows below that top — not five.
        cursor: i32 = 0,
        /// The window's last screen row, or -1 while the app has reported
        /// no winsize. Then no move clamps and no movement is credited:
        /// with no viewport there is nothing to be exact about, and the
        /// safe reading is that the cursor is where it was.
        last_row: i32 = -1,
        /// Charge `n` rows walked UP (CUU, CPL). Clamped at the window's
        /// first visible row: there is no row above it, whatever the
        /// window's height is.
        fn up(self: *Frame, n: anytype) void {
            if (self.last_row < 0 or n == 0) return;
            const step: i32 = @intCast(n);
            self.cursor = @max(0, self.cursor - step);
            self.query_shift -= step;
            self.query_low = @max(0, self.query_low - step);
            self.query_high = @max(0, self.query_high - step);
        }
        /// Charge `n` rows walked DOWN — a CUD, a CNL, or a newline. All
        /// three stop at the window's last row, and there the newline
        /// scrolls the window and leaves the cursor exactly on that row:
        /// same row, same clamp, so one charge serves all of them and no
        /// scroll counter is needed.
        fn down(self: *Frame, n: anytype) void {
            if (self.last_row < 0 or n == 0) return;
            const step: i32 = @intCast(n);
            self.cursor = @min(self.last_row, self.cursor + step);
            self.query_shift += step;
            self.query_low = @min(self.last_row, self.query_low + step);
            self.query_high = @min(self.last_row, self.query_high +| step);
        }
    };

    /// How a frame hands the rows it took off the TOP of the band to the
    /// ownership ledger above it.
    const LedgerOut = struct {
        /// Old logical band rows whose source this frame copies into
        /// the ledger. A physical re-base copies only its clipped prefix.
        rows: u32,
        /// How many of THOSE are out of reach, taken from the band's TOP.
        /// They are the band's own uncommitted text — a terminal that
        /// hands its scrollback back would show the popup twice — and are
        /// erased once the viewport shows them again. Rows above the band
        /// are never part of this count: they are committed, and a clip
        /// that spent one does not make it the band's to erase.
        retired_rows: u32,
        /// Physical chunks of the NEXT band row that retire with them. A
        /// native band row can be several physical rows tall and the clip
        /// boundary can fall inside one, so that row is split at the
        /// exact chunk cut instead of being retired or settled whole:
        /// half a hard group is not a group the terminal ever had.
        retired_chunks: u32 = 0,
        /// What the rows the screen still shows become: hard blank rows a
        /// re-base erased over, or committed history a `.rebuild` left
        /// in the transcript.
        settled: enum { blank, committed } = .blank,
        /// Exact visible physical rows erased ABOVE the new band top by
        /// a physical re-base. These can span several logical rows even
        /// when the clip cuts inside the first one; their blank gap is
        /// independent of the logical prefix whose source is retired.
        erased_rows: ?u32 = null,
        /// Physical chunks the LAST settled band row keeps, when a
        /// `.rebuild` handed over the whole old extent: the cursor's own
        /// row is the one the repaint overwrites, so it never settles,
        /// and under a declared model the cursor's row can be several
        /// physical rows tall. `null` settles that row whole — what a
        /// `.collapse` and a re-base do, because neither of them paints
        /// over it.
        settled_chunks: ?u32 = null,
    };

    /// One hard logical group the Region owns ABOVE the band top.
    ///
    /// The text is never here: the ledger batch that carried it may be
    /// acknowledged and freed the moment its bytes are on the wire.
    /// What has to survive is the GEOMETRY the terminal was given —
    /// how many columns it painted and where its width-2 glyphs sat —
    /// because that is the only thing a reflow projection and a
    /// capacity trim can ask about. No glyph text is kept and no row
    /// allocates: the wide positions live on the region's one reused
    /// tape, indexed by the record.
    const Owned = struct {
        /// The emitted geometry of this group, or `.{}` where the
        /// declared model is `.none` (every group is one row then) or
        /// where the group is a blank run.
        fp: Buffer.RowFootprint = .{},
        kind: enum {
            /// The band painted it and a physical clip took it. Still
            /// the live popup's own uncommitted text: a terminal that
            /// hands its scrollback back would show the popup twice, so
            /// it is erased row-scoped the moment the viewport shows it
            /// again — and only while it is reachable.
            retired,
            /// Written above the band by the Region: a `.line`, a
            /// `.text`, a history batch, or a `.rebuild` row settled as
            /// history. Never erasable, and never dropped while the
            /// declared capacity says the terminal still holds it.
            committed,
            /// Hard blank rows: what a released or erased tail leaves
            /// between owned groups. They are padding the projection
            /// has to count and nothing else — never erasable, never
            /// trimmed, and held as a RUN because a blank row has no
            /// geometry to describe.
            blank,
        } = .retired,
        /// The physical rows this group occupies at the width the
        /// terminal has now, and for a `.blank` group the length of its
        /// run (a blank row has no geometry to project, so its count IS
        /// its extent and nothing else could answer it).
        rows: u32 = 1,
    };

    /// A logical band row's surviving source and physical extent.
    /// Zero rows records irreversible front eviction without renumbering
    /// the logical rows that a later frame may paint again.
    const BandRow = struct {
        fp: Buffer.RowFootprint,
        rows: u32 = 1,
    };

    /// Ledger admission failures; no batch is admitted on error.
    pub const WriteHistoryError = error{ DuplicateHistoryId, HistoryTooLarge, OutOfMemory };
    /// The id is not a retained, written, unacknowledged batch.
    pub const AcknowledgeError = error{UnknownHistoryId};

    /// Stored allocation provider for grids, copied rows, and geometry. Do not replace it.
    gpa: std.mem.Allocator,
    /// Borrowed view of the current drawing grid; do not separately deinitialize it.
    cur: Buffer,
    /// Read-only committed snapshot; owns graphemes but still borrows style hyperlinks.
    prev: Buffer,
    /// The replacement grid for the committed snapshot, staged by the
    /// frame in flight when the external geometry has moved it and
    /// published by the commit that staged every byte.
    ///
    /// It exists because the publish is a flat copy of `cur`'s grid into
    /// `prev`'s and needs both to be the same length, while a reshape is
    /// the one step that ALLOCATES — and a frame that dies staging its
    /// bytes must leave the committed snapshot exactly as the last
    /// successful composition left it. Reshaping `prev` in place would
    /// make the shape follow the RESIZE rather than the commit, so a
    /// writer failure would have changed the committed snapshot's shape
    /// with no frame behind it. Staged here and swapped only at commit,
    /// both halves of the contract hold: prepared before the first byte,
    /// published only on success.
    prev_next: ?Buffer = null,
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
    snapshot_cells: std.ArrayList([]const u8) = .empty,
    opts: Options,

    /// Band rows that still hold PAINTED CONTENT. The diff erases from
    /// the content end up to this mark, row-scoped, so a row the frame
    /// no longer paints is blanked instead of lingering — which is why
    /// the mark can sit BELOW `painted_rows` (a frame that empties the
    /// band drops it to 0 while the rows themselves stay the band's).
    /// It is a content mark, never an extent: `painted_rows` is the
    /// extent, and every cursor move uses that one.
    high_water: u16 = 0,
    /// Terminal rows the band PHYSICALLY occupies right now. Not the
    /// same as `height` after a collapse or before a reserve ran; every
    /// cursor move uses this, never `new - old`. It is also what a
    /// height change is measured AGAINST, so a run of changes settles
    /// once, on the net difference (see `noteHeightChange`).
    painted_rows: u16 = 0,
    /// A CPR measurement is owed. Normally the query follows the paint
    /// and park; a clipped width change measures before repainting.
    /// The single query slot prevents repeated requests while a terminal
    /// is slow to answer.
    anchor_dirty: bool = true,
    /// A width change / forced full redraw is due.
    width_dirty: bool = false,
    /// The band must grow, shrink or be re-created before the next diff
    /// can trust its own rows. Set only when the requested height is
    /// not the extent already on screen, so a run of changes that
    /// settles back onto it leaves no work owed.
    height_dirty: bool = false,
    /// Visible rows of the terminal the app last reported (`winsize`
    /// rows); 0 while it has reported none, and only `resize` ever
    /// records one. `physical_dirty` is set only beside a non-zero
    /// value, so a painter that sees the flag always has a viewport.
    term_rows: u16 = 0,
    /// A physical height change left rows of the band outside the
    /// viewport, so the next frame repaints the whole surviving band
    /// instead of diffing it: `prev` still holds the text of rows the
    /// screen no longer shows. Cleared by the frame that repainted or
    /// released the band, and never before — a frame that dies
    /// staging its bytes must retry the same repaint.
    physical_dirty: bool = false,
    /// One query is outstanding and its reply has not arrived. The
    /// reply is untagged, so this is the only thing that can say
    /// whether an incoming `cpr` is an answer or noise — and it is held
    /// (never abandoned) until that reply is consumed or discarded.
    query_outstanding: bool = false,
    /// The outstanding query was asked under an older geometry
    /// generation: whatever it answers describes rows the region has
    /// stopped tracking, so the reply is discarded and one fresh
    /// query replaces it.
    query_stale: bool = false,
    /// The geometry generation every reply is judged against, and the
    /// one the last accepted reply actually measured. A report is only
    /// usable while they are equal.
    geom_gen: u64 = 1,
    /// An external geometry transition is waiting to be accounted. A
    /// purely logical change — the app resizing its band between frames —
    /// leaves the terminal's geometry alone and must not repack
    /// anything.
    geom_dirty: bool = false,
    query_gen: u64 = 0,
    measured_gen: u64 = 0,
    /// The transform from the row the outstanding query was asked about
    /// to the row the cursor is on now, composed across every frame that
    /// committed while it waited: a shift, and the window of rows the
    /// walk can currently be at. Seeded when the query goes out, extended
    /// at each move seam, and applied once when the reply lands.
    query_shift: i32 = 0,
    query_low: i32 = 0,
    query_high: i32 = 0,
    /// Whether the tracked cursor row is still the row the terminal
    /// really has. A declared native model repacks the rows AROUND the
    /// cursor and a physical height change clamps it, so either
    /// invalidates it until a fresh reply re-establishes it — and no
    /// retirement erase may run on a guess, because a walk clamped onto
    /// the viewport's first row blanks committed history.
    reach_known: bool = false,
    /// Every hard logical group the Region owns above the band top,
    /// ordered from the EARLIEST one to the one nearest the band top.
    /// The band top is the reference, never a stored offset: rows the
    /// region writes above it land at the tail and rows it hands back
    /// come off the top, so a band-top shift re-derives every offset
    /// instead of carrying a counter that can drift. Committed rows and
    /// the gaps between them live here as well as the retired ones —
    /// a capacity trim may remove either, and only the ledger knows
    /// which is which.
    owned: std.ArrayList(Owned) = .empty,
    /// The ledger or its tapes hold something a reclaim pass has not
    /// taken yet: a group removed out of the middle, a survivor rebased
    /// onto the tail of a tape, or a blank run that landed next to
    /// another. Set by the only three places that can produce one, so
    /// the pass runs on the frames that CHANGED the ledger and not on
    /// every commit — a steady session would otherwise walk a ledger
    /// that has not changed since the last walk, once per frame, for
    /// the rest of the session.
    ledger_dirty: bool = false,
    /// Width-2 glyph positions for every `Owned.fp`, in ledger order;
    /// a record's positions are `wide_tape[fp.wide_start..][0..fp.wide_count]`.
    /// Rows without a wide glyph append nothing, so an ASCII-only
    /// session never touches it.
    wide_tape: std.ArrayList(u16) = .empty,
    /// Unprinted intervals for every `Owned.fp`, in the same order.
    /// A record's are `null_tape[fp.null_start..][0..fp.null_count]`.
    /// They are what separates a row that merely SPANNED a wide stretch
    /// from one that painted it: both have the same columns and the same
    /// wide positions, and only the gaps tell the next reflow that the
    /// second is blank however narrow the window gets.
    null_tape: std.ArrayList(Buffer.RowFootprint.NullGap) = .empty,
    /// Surviving band geometry, indexed by logical row, on the band tapes.
    /// Physical counts are published by paint and updated only by geometry
    /// transitions. An evicted source cannot return at the next width.
    /// Empty while no native model is declared.
    band_fp: std.ArrayList(BandRow) = .empty,
    band_tape: std.ArrayList(u16) = .empty,
    band_gaps: std.ArrayList(Buffer.RowFootprint.NullGap) = .empty,
    /// Ledger entries this frame staged, published only at commit.
    /// Spliced at the tail in the order the frame wrote or handed them
    /// over, which is the order they appear on screen.
    pending_owned: std.ArrayList(Owned) = .empty,
    /// Rows those staged entries hold, known before the first byte so
    /// every position they will append can be reserved.
    pending_rows: usize = 0,
    /// The band rows' geometry as the frame in flight composed them,
    /// with the tapes they index. Cleared and rebuilt per capture, so a
    /// frame that dies staging never leaves half a row behind.
    pending_band: std.ArrayList(BandRow) = .empty,
    band_next: std.ArrayList(u16) = .empty,
    band_next_gaps: std.ArrayList(Buffer.RowFootprint.NullGap) = .empty,
    // The rows above the band top the viewport can still show are not a
    // counter: `reach()` derives them from the cursor row and the
    // extent, so the erase and the walk that serves it can never
    // disagree about a row.
    /// The cursor's offset below the band top where the next frame
    /// starts: the band bottom, or — while the band is released — the
    /// settled row a `collapse` parked it on. Every frame ends parked on
    /// the band bottom, so this is that row the erase walks down from.
    cursor_off: i32 = 0,
    /// The cursor's row as the screen shows it, counted from the window's
    /// first visible row, and an UPPER BOUND on it: it is never smaller
    /// than the row the terminal really has the cursor on.
    ///
    /// Within a frame it is walked in order — `Frame.cursor` moves on
    /// every emitted CUU, newline and CUD, clamped at both edges of the
    /// viewport — so it is exact for as long as it starts exact. A
    /// window dragged shorter keeps the cursor's LINE: the cursor stays
    /// put while its row still fits and lands on the new last row only
    /// when it does not, so `notePhysicalRows` clamps and never assumes
    /// a mid-window cursor was dragged along to the bottom.
    ///
    /// A column change retires it too, but only under a declared native
    /// model and only as a REACH, never as a number: the repack moves
    /// the cursor's row without the Region knowing by how much, so
    /// `reach_known` goes false and every erase waits for a fresh reply
    /// instead of reading this field.
    ///
    /// That row is what decides how the NEXT taller window grows — a
    /// pull while the cursor is on the last one, blank rows below it
    /// anywhere else — and how many rows above the band top the screen
    /// can be holding. It stays 0 until the app reports a winsize, which
    /// is the safe reading: nothing is credited from a cursor nobody has
    /// located. The one place it can still over-state is a pull: the
    /// region credits the whole growth to the cursor and does not know
    /// how much scrollback the terminal actually had to hand back (a
    /// window whose scrollback ran out appends the rest BELOW the
    /// cursor and moves it by less). Over-stating there only ever makes
    /// the region look at rows it is not sure about, which is why a
    /// declared native model refuses to erase on a tracked row at all:
    /// under that model the tracked row is not measured until a reply
    /// says so — see `reach_known` and `nearestRetired`.
    cursor_screen: u16 = 0,
    /// The region has not rendered yet (strategy `first` pending).
    first_frame: bool = true,
    /// The band is released (`height == 0` and nothing is painted).
    /// Derived from those two, never latched: it is recomputed whenever
    /// the height or the extent changes.
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
    /// Queue metadata is Region-owned; `Append` payloads remain caller-borrowed.
    append_queue: std.ArrayList(Append) = .empty,
    /// The width the band is currently painted at (`.preserve` reflow).
    last_width: u16 = 80,
    /// Retained ledger batches, in write order. The first
    /// `history_written` are staged into the byte stream; the rest are
    /// still unwritten. Everything here is released on acknowledgement.
    history: std.ArrayList(OwnedBatch) = .empty,
    history_written: usize = 0,
    history_bytes: usize = 0,
    /// Highest batch id accepted.
    history_high: u64 = 0,
    /// Receipts of the batches a transport drained (`.acknowledgeDrained`).
    history_ids: std.ArrayList(u64) = .empty,
    /// Scratch for `historyPending` (no allocation in steady state).
    history_pending_buf: std.ArrayList(u64) = .empty,

    /// Buffer width (mirrors `cur.width`; default 80 until the app
    /// resizes from the terminal winsize).
    width: u16,
    /// Buffer height (mirrors `cur.height`; from `opts.height`).
    height: u16,

    /// Region-owned copied history payload, released only by the Region.
    /// Copies alias the row array. `bytes` includes each row's line terminator;
    /// `acked` marks transport/product acknowledgement pending ordered prefix release.
    const OwnedBatch = struct {
        id: u64,
        kind: @FieldType(HistoryBatch, "kind"),
        /// Owned row copies, in order.
        rows: [][]u8,
        bytes: usize,
        /// Append queue boundary at submission. Only unwritten batches use it;
        /// both queues settle together, so retained receipts need no rebasing.
        appends_before: usize,
        acked: bool = false,
    };

    /// Allocate the double buffer and the ledger state.
    ///
    /// Buffers start 80 columns wide — a zero-width buffer would
    /// silently drop the first frame's draws until a resize arrives.
    /// On `error.OutOfMemory` no owner escapes and every partial allocation is released.
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

    /// Release grids, copied history, snapshots, and geometry through the stored allocator.
    /// Does not emit terminal teardown; call `exit` first if needed. Invalidates all views.
    /// The owner is unusable afterward; repeated disposal or disposing a copy is invalid.
    pub fn deinit(self: *Region) void {
        for (self.history.items) |b| self.releaseBatch(b);
        self.history.deinit(self.gpa);
        self.history_ids.deinit(self.gpa);
        self.history_pending_buf.deinit(self.gpa);
        self.snapshot_cells.deinit(self.gpa);
        self.owned.deinit(self.gpa);
        self.wide_tape.deinit(self.gpa);
        self.band_fp.deinit(self.gpa);
        self.band_tape.deinit(self.gpa);
        self.null_tape.deinit(self.gpa);
        self.band_gaps.deinit(self.gpa);
        self.pending_owned.deinit(self.gpa);
        self.pending_band.deinit(self.gpa);
        self.band_next.deinit(self.gpa);
        self.band_next_gaps.deinit(self.gpa);
        self.snapshot_scratch.deinit();
        self.prev_text.deinit();
        self.append_queue.deinit(self.gpa);
        self.cur.deinit();
        self.prev.deinit();
        if (self.prev_next) |staged| self.gpa.free(staged.cells);
        self.* = undefined;
    }

    /// Reallocate the drawing buffer, mark the next frame for a resize
    /// repaint and a CPR re-query, and record the screen the band is
    /// being composed for. A pure height change routes to
    /// `setSizedHeight` (no width repaint).
    ///
    /// `terminal_rows` is what the terminal VISIBLY has (`winsize`
    /// rows), `new_height` the logical band height the app wants. A
    /// caller that only means to move the band around inside the same
    /// screen — a popup opening and closing — uses `setHeight`, which
    /// records no viewport and so never forces the repaint a physical
    /// change needs.
    ///
    /// A width change that arrives WITH a height change settles both in
    /// one frame: `paintResize` repaints (and, in `.preserve`, releases
    /// or reserves the rows) at the new height, so the height is not
    /// left owed to a later frame.
    ///
    /// The geometry the terminal has already applied is accounted HERE,
    /// once per observed transition, and not at the next frame: a
    /// coalesced burst of widths (131, then 55, then 66, then 3, all
    /// before one render) repacks the content at every one of them, and a
    /// Region that only looked at the last would skip the capacity loss
    /// an intermediate width caused. It is accounted before any frame
    /// byte is composed, so it is not repeated by a retry.
    /// `error.OutOfMemory` leaves the old grid and geometry unchanged. Success invalidates
    /// pointers into `cur.cells`; drawn text and prior-snapshot borrows are not released.
    pub fn resize(self: *Region, new_width: u16, terminal_rows: u16, new_height: u16) !void {
        if (new_width == self.width) return self.setSizedHeight(terminal_rows, new_height);
        try self.reshape(new_width, new_height);
        // The terminal adjusts viewport retention before width reflow.
        // Trim against the old packing first if this resize also changes height.
        self.notePhysicalRows(terminal_rows);
        self.trimToCapacity();
        self.width = new_width;
        self.width_dirty = true;
        self.invalidateGeometry();
        self.noteHeightChange(new_height);
        self.applyGeometry(true);
    }

    /// `setHeight` with the terminal's visible rows beside it: the
    /// width-preserving resize, and the only entry point a pure
    /// viewport change takes. `terminal_rows` 0 is a record of nothing.
    fn setSizedHeight(self: *Region, terminal_rows: u16, new_height: u16) !void {
        const physical = terminal_rows != 0 and terminal_rows != self.term_rows;
        if (!physical and new_height == self.height) return;
        if (new_height != self.height) try self.reshape(self.width, new_height);
        self.notePhysicalRows(terminal_rows);
        self.noteHeightChange(new_height);
        self.applyGeometry(false);
    }

    /// Move `cur` to the new grid shape.
    ///
    /// `prev` is NOT reshaped here. A frame publishes the next snapshot
    /// by copying one grid into the other, so the two have to stand on
    /// the same shape at the instant of that copy — and a reshape is the
    /// one step that ALLOCATES, so the committed snapshot must not move
    /// on a resize that the next frame may never publish into. Each
    /// `Buffer.resize` also frees the grid it replaced, which is why
    /// reshaping both here would leave the two on different shapes with
    /// one grid already gone whenever the second allocation failed.
    ///
    /// The replacement is staged by the frame that will publish it
    /// (`prepareSnapshot` into `prev_next`) and swapped in by the commit
    /// (`publishSnapshot`): prepared before the first byte, published
    /// only once every byte is staged.
    fn reshape(self: *Region, new_width: u16, new_height: u16) error{OutOfMemory}!void {
        try self.cur.resize(new_width, new_height);
    }

    fn nativeReflow(self: *const Region) bool {
        return switch (self.opts.terminal_reflow) {
            .none => false,
            .non_cursor_rows => true,
        };
    }

    fn scrollbackCapacity(self: *const Region) u32 {
        return switch (self.opts.terminal_reflow) {
            .none => 0,
            .non_cursor_rows => |native| native.scrollback_rows,
        };
    }

    /// Account the geometry the terminal has just applied: repack every
    /// group the Region owns and every band row it painted, then let the
    /// declared capacity take whatever the terminal has discarded.
    ///
    /// It runs where the external transition is observed rather than in
    /// the next frame, so a burst of widths a session coalesces into one
    /// render is still accounted once per width — and it runs before any
    /// byte is composed, so a frame that dies staging its bytes never
    /// accounts the same transition twice. The repack is idempotent, so
    /// a retry that reaches it again is a no-op rather than a second
    /// application.
    fn applyGeometry(self: *Region, width_changed: bool) void {
        if (!self.nativeReflow() or !self.geom_dirty) return;
        self.geom_dirty = false;
        if (width_changed) {
            self.refreshLedger();
            self.refreshBand();
        }
        // Every observed width is accounted on its own, which is what
        // makes a coalesced burst irreversible step by step rather than
        // once at its last: the repack is the geometry the next packing
        // reads, and the trim drops what the terminal dropped at THIS
        // width. Frame commit applies retention again after publishing
        // any newly painted rows.
        self.trimToCapacity();
    }

    /// Record the rows the terminal visibly has. A screen too short to
    /// hold the rows the band occupies scrolled the top of that extent
    /// into scrollback, where no relative move reaches it again: the
    /// frame that repaints has to write EVERY surviving row, because
    /// `prev` still holds the text of rows the screen no longer shows.
    ///
    /// Nothing else is published here — in particular not the extent.
    /// `painted_rows` is what the last frame settled and a frame that
    /// dies staging its bytes must find it standing, so the surviving
    /// band is still measured against the OLD one.
    fn notePhysicalRows(self: *Region, terminal_rows: u16) void {
        if (terminal_rows == 0) return;
        const was = self.term_rows;
        self.term_rows = terminal_rows;
        if (terminal_rows != was) self.invalidateGeometry();
        if (terminal_rows < self.painted_rows) self.physical_dirty = true;
        if (terminal_rows < was or terminal_rows < self.painted_rows) {
            // A window dragged shorter keeps the cursor's LINE: the rows
            // above it that no longer fit become scrollback and the rows
            // it gives up are the blank tail below it. The cursor is
            // therefore dragged onto the new last row ONLY when its own
            // line no longer fits — a band parked mid-window under a
            // taller window keeps the row it is on, and a reach read off
            // `term_rows` would claim rows the screen never gave back.
            //
            // The frame that re-bases the band retires the rest of what
            // the band gave up and shifts the offsets past it; the rows
            // that are still reachable need no counter here.
            self.cursor_screen = @min(self.cursor_screen, terminal_rows - 1);
            return;
        }
        if (terminal_rows == was) return;
        if (was == 0) return; // the first winsize: no viewport to reason from yet
        if (!self.cursorAtWindowBottom(was)) {
            // The cursor is not on the window's last row, so a window
            // that grows here grows DOWNWARD: xterm's observed
            // `Buffer.resize` appends blank lines below the cursor and
            // leaves `ybase`/`ydisp` alone. Nothing above the band top
            // becomes visible, so nothing may be credited — and a run
            // that stays out of reach stays tracked, not reclaimed.
            return;
        }
        // A pull. The window handed back AT MOST its own growth: it had
        // to have that much scrollback above it, and a terminal whose
        // scrollback ran out appends the rest below the cursor instead
        // (xterm again), which moves the cursor by less. Crediting the
        // whole growth can only over-state the cursor row, and the erase
        // that reads it is bounded by the tracked run as well — an
        // unreachable row stays tracked rather than guessed at.
        self.cursor_screen +|= terminal_rows - was;
    }

    /// Retire every measurement of the geometry that just changed.
    ///
    /// The generation is the region-wide clock the CPR protocol runs
    /// on: a reply is only an answer to the query that is outstanding
    /// AND was asked under the generation that is live now. A column
    /// change or a new visible height moves both, so the query already
    /// in flight cannot be trusted and the slot it holds stays held
    /// until that reply lands — there is only ever one query, and
    /// abandoning the slot would make two untagged answers
    /// indistinguishable.
    fn invalidateGeometry(self: *Region) void {
        self.geom_gen +%= 1;
        if (self.geom_gen == 0) self.geom_gen = 1; // reserved as "never measured"
        self.anchor_dirty = true;
        self.geom_dirty = true;
        if (self.query_outstanding) self.query_stale = true;
        // The tracked cursor ROW goes with it, on a column change as
        // surely as on a height change. Exempting the cursor's own
        // group is not the same as exempting the cursor's row: the
        // group itself is not repacked, but every group ABOVE it is,
        // and the rows those take push the cursor down the screen. An
        // installed xterm measured at 131 columns puts its cursor on
        // screen row 1 with one non-cursor group of 131 logical
        // columns above it; at 55 that same group is three physical
        // rows and the cursor is on screen row 3; back at 131 it is row
        // 1 again. Reading the trim and the retirement erase off the
        // old row would then discard rows the terminal still has and
        // erase rows the walk cannot reach — so the reach is unknown
        // until a reply measures it again, and every erase waits for
        // that.
        self.invalidateReach();
    }

    /// Absolute reach is unknown after geometry changes in either model.
    /// A correct relative repaint does not make an overlarge erase safe.
    fn invalidateReach(self: *Region) void {
        self.reach_known = false;
    }

    /// Physical rows one ledger group occupies at the width the terminal
    /// has NOW.
    ///
    /// It is the record's own count, not a recomputation, because a
    /// group whose suffix an erase took keeps the physical chunks the
    /// screen is still showing even after its logical source is trimmed
    /// back to the last cell that was really painted — and those two
    /// deliberately disagree. The count is repacked only when the
    /// geometry actually changes, which is the only event that can move
    /// the terminal's rows.
    fn groupRows(self: *const Region, g: Owned) u32 {
        _ = self;
        return g.rows;
    }

    /// Repack every ledger group for a width the terminal has just
    /// changed, and re-derive each one's logical source: the full
    /// non-final chunks the group already has, plus whatever the NEW last
    /// chunk reaches, with its unprinted tail trimmed back to the last
    /// painted cell.
    ///
    /// Repacking from the trimmed source rather than from the row the
    /// group was originally written as is the whole point: an erased
    /// suffix must never come back because the group still remembers its
    /// full width.
    fn refreshLedger(self: *Region) void {
        for (self.owned.items) |*g| {
            if (g.kind == .blank) continue;
            if (!self.nativeReflow()) {
                g.rows = 1;
                continue;
            }
            g.rows = g.fp.rowsAt(self.wide_tape.items, self.width);
            g.fp.columns = flatten(
                g.fp,
                self.wide_tape.items,
                self.null_tape.items,
                self.width,
                g.rows,
            );
        }
    }

    /// The logical source a group of `chunks` physical rows carries
    /// forward, at the width it is packed at.
    ///
    /// The terminal flattens a wrapped group by counting every
    /// non-final chunk FULL and trimming only the final chunk's
    /// unprinted tail. So the source is the largest of two things: the
    /// extent the non-final chunks cover, and the last chunk's end with
    /// its trailing NULLs walked back. Trimming the WHOLE prefix instead
    /// — the obvious reading, and what a single suffix cut wants — loses
    /// every full non-final chunk and collapses a two-chunk unprinted
    /// survivor from nineteen rows to one; trimming nothing at all leaves
    /// a survivor that reflows as rows that were never printed. Both are
    /// wrong in the same direction: one hides content the terminal still
    /// has, the other invents height it does not.
    fn flatten(
        fp: Buffer.RowFootprint,
        wide: []const u16,
        gaps: []const Buffer.RowFootprint.NullGap,
        width: u16,
        chunks: u32,
    ) u16 {
        if (chunks == 0 or fp.columns == 0) return 0;
        const last = fp.prefixRows(wide, width, chunks);
        const painted = last.paintedPrefixColumns(gaps, last.columns);
        if (chunks == 1) return painted;
        const head = fp.prefixRows(wide, width, chunks - 1).columns;
        return @max(head, painted);
    }

    /// Rows the ledger holds above the band top at the current width.
    fn ownedRows(self: *const Region) u32 {
        var total: u32 = 0;
        for (self.owned.items) |g| total += self.groupRows(g);
        return total;
    }

    /// Rows the band itself occupies at the current width: its committed
    /// geometry, projected.
    ///
    /// The row the CURSOR is on is exempt from that projection under a
    /// declared native model, on narrowing and on widening alike: the
    /// terminal leaves the cursor's whole group alone, so it stays one
    /// physical row however the columns move. Counting it as anything
    /// else would make the Region walk a distance the terminal never
    /// took — on a shrink that reaches into the transcript, and on a
    /// growth it reserves rows that already exist.
    ///
    /// A band that owns no rows projects to no rows, and NOT to the one
    /// row the exemption would otherwise credit it: the state exists
    /// between `init` and the first reserve, on a height that reached
    /// zero, and for the whole of a `.collapse` commit — and the
    /// exemption is a property of a group, of which an empty footprint
    /// has none.
    ///
    /// Without a declared native model that is exactly `painted_rows`,
    /// which is why every extent in this file is written in terms of this
    /// one call.
    fn bandRows(self: *const Region) u32 {
        if (!self.nativeReflow()) return self.painted_rows;
        if (self.band_fp.items.len != self.painted_rows) return self.painted_rows;
        if (self.band_fp.items.len == 0) return 0;
        var total: u32 = 0;
        for (self.band_fp.items) |row| total += row.rows;
        return total;
    }

    /// Physical rows band row `y` occupies at the width the terminal has
    /// now — one for the row the cursor is on, and one for every row
    /// without a declared native model, because that is the model the
    /// band is composed under.
    fn bandRowRows(self: *const Region, y: u32) u32 {
        if (!self.nativeReflow() or y >= self.band_fp.items.len) return 1;
        return self.band_fp.items[y].rows;
    }

    /// What a physical clip put out of the viewport's reach: whole band
    /// rows taken from the TOP, plus the physical chunks of the row after
    /// them when the boundary falls inside one.
    ///
    /// ONE projection for every frame that hands band rows to the ledger
    /// while a clip is in force, so a `.physical` re-base and a
    /// `.collapse` under the same clip cannot disagree about which rows
    /// the window cannot show — and so neither has to grow its own copy
    /// of the walk.
    ///
    /// Zero without a reported winsize: with no window there is nothing
    /// out of reach, and claiming a clip no terminal reported would
    /// retire rows the screen still holds.
    const Clip = struct { rows: u32, chunks: u32 };

    fn clipped(self: *const Region) Clip {
        if (self.term_rows == 0) return .{ .rows = 0, .chunks = 0 };
        const band = self.bandRows();
        const budget = band -| self.reachableBandRows();
        var whole: u32 = 0;
        var walked: u32 = 0;
        while (whole < self.painted_rows and walked + self.bandRowRows(whole) <= budget) {
            walked += self.bandRowRows(whole);
            whole += 1;
        }
        const cut = whole < self.painted_rows and walked < budget;
        return .{ .rows = whole, .chunks = if (cut) budget - walked else 0 };
    }

    /// A combined resize can leave the cursor above the viewport bottom:
    /// multiplexers keep reflowed continuation rows below its hard row.
    /// A measured cursor bounds the surviving prefix, not just winsize.
    fn reachableBandRows(self: *const Region) u32 {
        const rows: u32 = if (self.reach_known)
            @as(u32, self.cursor_screen) + 1
        else
            self.term_rows;
        return @min(self.bandRows(), rows);
    }

    /// Repack the band's own committed geometry for a width the terminal
    /// has just changed, the same way the ledger is repacked: every row
    /// but the cursor's goes through the flatten rule, and the cursor's
    /// row keeps the single physical row it has on both a shrink and a
    /// growth.
    ///
    /// Empty is empty: there is no cursor group to leave alone in a band
    /// that owns no rows, and `items[0 .. len - 1]` of nothing is the
    /// crash a startup resize to a width the 80-column default never
    /// had, or a width change after a `.collapse` commit, would reach.
    fn refreshBand(self: *Region) void {
        if (!self.nativeReflow() or self.band_fp.items.len != self.painted_rows) return;
        if (self.band_fp.items.len == 0) return;
        const last = self.band_fp.items.len - 1;
        for (self.band_fp.items[0..last]) |*row| {
            if (row.rows == 0 or row.fp.columns == 0) continue;
            row.rows = row.fp.rowsAt(self.band_tape.items, self.width);
            row.fp.columns = flatten(
                row.fp,
                self.band_tape.items,
                self.band_gaps.items,
                self.width,
                row.rows,
            );
        }
        // Exemption is not retention: the current hard row is clipped in
        // place. A collapse before repaint must not archive its lost tail.
        var cursor = self.band_fp.items[last].fp.prefixRows(self.band_tape.items, self.width, 1);
        cursor.columns = cursor.paintedPrefixColumns(self.band_gaps.items, cursor.columns);
        self.band_fp.items[last] = .{ .fp = cursor };
    }

    /// The screen row the band top sits on: the cursor's own row less the
    /// offset it is below that top. Retired row `offset` is reachable
    /// exactly while `offset <= reach()`, and that is what bounds the
    /// erase walk — a CUU past this many rows would clamp onto the
    /// window's first row and blank whatever is on it, and that row is
    /// committed history.
    ///
    /// DERIVED, never accumulated: the cursor row is walked in order by
    /// every frame (see `Frame.cursor`) and the offset is what the last
    /// frame settled, so the two cannot drift apart the way a counter
    /// charged once per event can. A newline that scrolled the window
    /// instead of moving the cursor needs no counter of its own — the
    /// cursor is left on the last row either way, which is exactly what
    /// it was on before. A RELEASED band owns no rows but still has runs
    /// owed above it, and answers for the row its released content sits
    /// on. Negative while the band top is above the viewport, and -1
    /// while no winsize has been reported at all: with no viewport
    /// nothing is reachable.
    fn reach(self: *const Region) i32 {
        if (self.term_rows == 0) return -1;
        return @as(i32, self.cursor_screen) - self.cursor_off;
    }

    /// Whether the cursor sits on the window's last row in a window of
    /// `term_rows` rows, which is what decides how that window grows: on
    /// that row a taller window pulls its scrollback back onto the
    /// screen, and anywhere else it appends empty rows below the cursor
    /// instead, leaving everything above the band exactly where it was.
    fn cursorAtWindowBottom(self: *const Region, term_rows: u16) bool {
        return self.cursor_screen +| 1 == term_rows;
    }

    /// Height-only resize of the drawing grid; the prior snapshot changes only at render.
    /// Marks the next frame for `height` or `collapse`; unchanged height is a no-op.
    /// `error.OutOfMemory` leaves the old grid and geometry unchanged.
    ///
    /// Growth always reserves the new rows with CRLF: without a
    /// physical reservation the band would not exist on screen and the
    /// diff would paint rows that are not there. `Options.append_lines`
    /// governs only the FIRST-frame reservation. Shrink erases the
    /// removed tail row-scoped (EL) and never touches committed history.
    /// `new_height == 0` releases the band (`.collapse`): the rows stay
    /// on screen as settled content and the next non-zero height
    /// re-reserves from the cursor.
    ///
    /// Calls COALESCE. A session may shrink and regrow a band between
    /// two renders (the REPL popup opens and closes inside one tick), so
    /// nothing here records a per-call delta: the pending work is the
    /// difference between `new_height` and the extent the band already
    /// occupies, and a run of calls that settles back onto the extent on
    /// screen owes nothing at all. A frame that moved the terminal by
    /// the last call's delta would strand rows above the band, which the
    /// band no longer owns and may therefore never erase.
    ///
    /// LOGICAL only: it knows nothing about the terminal's visible
    /// height, so a caller that saw the screen change passes the
    /// winsize rows through `resize` instead — otherwise the rows a
    /// shrink scrolled out of reach keep the text `prev` holds and are
    /// never repainted.
    pub fn setHeight(self: *Region, new_height: u16) !void {
        // No viewport to record: a caller that does not know the
        // terminal's height cannot claim that it changed.
        return self.setSizedHeight(0, new_height);
    }

    /// Record one height change, measured against the band on screen.
    /// Both entry points funnel through here so a run of changes
    /// settles once, on the net difference:
    ///
    /// - a requested height equal to `painted_rows` is not a pending
    ///   change at all — the band already is that size on screen;
    /// - an INTERACTIVE band that occupies nothing (released by a
    ///   `collapse`) has to be RE-CREATED, so the next frame reserves it
    ///   from the cursor and re-queries the row it starts on. A height
    ///   that reaches 0 and comes back inside one tick releases nothing,
    ///   because no collapse frame ran, and must not re-reserve. The
    ///   gate matters on a pipe: `renderPlain` never publishes an
    ///   extent, so `painted_rows` stays 0 for the whole session and an
    ///   ungated re-arm would hand the pipe a second plain frame.
    fn noteHeightChange(self: *Region, new_height: u16) void {
        self.height = new_height;
        self.height_dirty = new_height != self.painted_rows;
        if (self.opts.interactive and new_height > 0 and self.painted_rows == 0) {
            self.first_frame = true;
            self.anchor_dirty = true;
        }
        self.collapsed = new_height == 0 and self.painted_rows == 0;
    }

    /// Queue `item` to flush ABOVE the region on the next render.
    /// Retains the slice without copying; `Append` states its lifetime and escape constraints.
    /// `error.OutOfMemory` leaves the queue unchanged.
    pub fn append(self: *Region, item: Append) !void {
        try self.append_queue.append(self.gpa, item);
    }

    /// Force a full redraw on the next render.
    /// On error the full redraw remains requested; `render` states writer-prefix recovery.
    pub fn renderFull(self: *Region, w: anytype) !void {
        self.repaintAll();
        try self.render(w);
    }

    /// Make the next render repaint every band row, as a width change does.
    ///
    /// A resize signal that ends on the geometry the band already has still
    /// means the terminal was some other size in between: SIGWINCH
    /// coalesces, and a window dragged narrow and back truncates the
    /// cursor's row on the way. `resize` with an unchanged size records
    /// nothing, so a host that saw a resize signal calls this as well.
    /// Allocates and emits nothing.
    pub fn repaintAll(self: *Region) void {
        self.width_dirty = true;
    }

    /// Mark the anchor as suspect; the next render re-queries CPR (the
    /// reply surfaces as `Event.cpr` for the app — see `applyCpr`).
    ///
    /// This is what a host calls after something it did not route through
    /// the Region wrote to the terminal — an external fd, a shell job, a
    /// subprocess — and that is exactly why a reply already in flight
    /// cannot be trusted here: it was asked before those bytes moved the
    /// cursor, and the walk the Region has composed since covers only the
    /// moves the Region itself made. The outstanding reply is marked
    /// stale so it is discarded rather than read through a gap in its own
    /// history; the slot stays held until it lands, and the frame after
    /// that asks once more.
    /// Allocates and emits nothing; the error set is empty for the uniform effect interface.
    pub fn reanchor(self: *Region) !void {
        self.anchor_dirty = true;
        if (self.query_outstanding) self.query_stale = true;
    }

    /// The desired cursor state for the paint envelope. The envelope
    /// hides the cursor when the app wants it hidden and shows it again
    /// on the frame that switches the desire (B2).
    pub fn setCursorHidden(self: *Region, hidden: bool) void {
        self.cursor_wanted_hidden = hidden;
    }

    /// Apply a Cursor Position Report (CPR) reply to the region's own
    /// outstanding `ESC[6n`.
    ///
    /// The reply is the cursor's 1-indexed row as the terminal had it
    /// WHEN IT ANSWERED. Normally the query follows the paint and park.
    /// A clipped width change measures the old bottom before repainting,
    /// so its reachable extent can be retired without guessing.
    /// Every frame that committed while the reply was in flight pushed
    /// the cursor on, in order and through the same viewport clamps, so a
    /// late reply is transformed by that composition (`query_shift` and
    /// the reachable window) onto the row the region is at NOW; reading
    /// it raw would anchor the band to where the cursor used to be, and
    /// taking the net distance instead would lose every clamp on the way.
    /// `col` is ignored: the parking is always column 1.
    ///
    /// The reply is untagged and only ONE query is ever outstanding, so
    /// the three cases are exhaustive and none of them guesses:
    ///
    /// - nothing outstanding — an unsolicited or duplicated report. It
    ///   changes nothing at all, because there is no frame it could be
    ///   describing.
    /// - the generation moved since the query — the report names rows
    ///   the region has stopped tracking. It is discarded, the owed
    ///   measurement stands, and the next committed frame asks once
    ///   more; the slot is never abandoned, because a second query in
    ///   flight would make two answers indistinguishable.
    /// - otherwise — the measurement. The anchor, the cursor row and
    ///   the reach every retirement erase is bounded by are published
    ///   from it, and the outstanding obligation clears.
    /// Allocates and emits nothing; the error set is empty for the uniform effect interface.
    pub fn applyCpr(self: *Region, row: u16, col: u16) !void {
        _ = col;
        if (!self.query_outstanding) return; // unsolicited or duplicate
        self.query_outstanding = false;
        if (self.query_stale) {
            self.query_stale = false;
            self.anchor_dirty = true;
            return;
        }
        // Every frame that committed while the query waited pushed the
        // walk through the same viewport boundary a real cursor would
        // have met, so `shift` plus the reachable window is the cursor's
        // row now. A window change invalidated the query outright above.
        var screen: i64 = @as(i64, row) - 1 + self.query_shift;
        self.query_shift = 0;
        if (screen < self.query_low) screen = self.query_low;
        if (screen > self.query_high) screen = self.query_high;
        if (screen < 0) screen = 0;
        if (self.term_rows > 0) screen = @min(screen, @as(i64, self.term_rows) - 1);
        self.cursor_screen = @intCast(screen);
        // The query is answered either way: leaving it owed would ask
        // again on the next tick for the rest of the session.
        self.anchor_dirty = false;
        // A released band has no bottom row to have asked about, so
        // nothing is measured: absolute placement stays unusable, and
        // the frame that re-creates a band is the one that asks again.
        if (self.painted_rows == 0) return;
        self.cursor_off = @as(i32, @intCast(self.bandRows() -| 1));
        self.measured_gen = self.query_gen;
        self.reach_known = true;
    }

    /// The absolute terminal row of the band top (1-indexed), or 0 when
    /// it cannot be used as a position: never rendered yet, no reply to
    /// the region's own query, the answer discarded because the geometry
    /// moved under it, a band that occupies no rows, or a band top that
    /// is not on the visible screen. Apps place absolute-row content —
    /// kitty graphics — at `anchorRow() + <band row>`, so 0 is the one
    /// value that must not be used as a row: it means "unusable", not
    /// "row 1".
    ///
    /// It is DERIVED from the measured cursor row and the band's current
    /// offset below it, never accumulated. An accumulator adds every row
    /// a frame pushed and every row it scrolled, which is exactly what
    /// goes wrong when the band grows onto the window's last row: the
    /// cursor moves and the band's top does not, so the sum places the
    /// graphic a screenful below the row the terminal put it on. A band
    /// top above the viewport is not a row anything can be placed on
    /// either, so that reads 0 rather than a negative row.
    ///
    /// The measurement this rests on is the region's own query, so a host
    /// that swallows `Event.cpr` leaves the anchor unusable rather than
    /// letting it drift.
    pub fn anchorRow(self: *const Region) u16 {
        if (self.measured_gen != self.geom_gen) return 0;
        if (self.painted_rows == 0) return 0;
        if (self.nativeReflow() and self.band_fp.items.len > 0 and
            self.band_fp.items[0].rows == 0) return 0;
        const top = @as(i64, self.cursor_screen) - self.cursor_off;
        if (top < 0 or top >= @as(i64, self.term_rows)) return 0;
        return @intCast(top + 1);
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
    /// Returns `error.AnchorUnmeasured` without output when `anchorRow()` is zero.
    /// `band_row` must be below `painted_rows`, and `col` must be in `1..width`.
    /// Writer errors can leave a partial image command or an unrestored cursor.
    pub fn placeAt(
        self: *Region,
        w: anytype,
        band_row: u32,
        col: u32,
        opts: PlaceAtOptions,
    ) !void {
        const top: u32 = self.anchorRow();
        if (top == 0) return error.AnchorUnmeasured;
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

    // ── ledger (C1) ──────────────────────────────

    /// Stage a ledger batch. The rows are copied into Region-owned
    /// memory bounded by `Options.max_history_bytes`; the caller keeps
    /// ownership of its slices.
    ///
    /// Ids are monotonic: a duplicate — still pending, already written,
    /// or already acknowledged — is `error.DuplicateHistoryId` and
    /// changes nothing. `error.HistoryTooLarge` when the retained bytes
    /// would exceed the bound; the batch is not staged, so nothing is
    /// ever dropped silently.
    /// OOM admits no batch or id; reusable metadata capacity may grow. The bound includes
    /// one line terminator per row, including empty rows.
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
            .appends_before = self.append_queue.items.len,
        });
        self.history_bytes += total;
        self.history_high = batch.id;
    }

    /// Stage `rows` as one ledger batch with the next Region-owned
    /// monotonic id and return that id — the receipt to hand back to
    /// `acknowledgeHistory` (or to the transcript's `commitReceipt`)
    /// once the transport accepted it. OOM or the retained-byte bound admits no batch;
    /// exhausted id space returns `error.HistoryIdExhausted` without changing the ledger.
    pub fn writeTranscript(
        self: *Region,
        rows: []const []const u8,
    ) (WriteHistoryError || error{HistoryIdExhausted})!u64 {
        const id = std.math.add(u64, self.history_high, 1) catch
            return error.HistoryIdExhausted;
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
    /// Borrows receipt storage until the next `acknowledgeDrained`, a `writeHistory`
    /// that grows that storage, or `deinit`. Copy ids before another such operation.
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

    /// Current cell differences against the last committed snapshot. Drawing can make this
    /// nonzero before rendering; a successful render republishes the snapshot and clears it.
    pub fn dirtyCells(self: *const Region) usize {
        var n: usize = 0;
        for (0..self.cur.height) |y| {
            for (0..self.cur.width) |x| {
                if (!self.cur.get(@intCast(x), @intCast(y)).eql(self.prev.get(@intCast(x), @intCast(y)))) n += 1;
            }
        }
        return n;
    }

    /// Retained batch ids, including written batches awaiting prefix release, in write order.
    /// Borrows query storage until the next successful `historyPending` or `deinit`.
    /// `error.OutOfMemory` leaves the ledger and the previous query result unchanged.
    pub fn historyPending(self: *Region) std.mem.Allocator.Error![]const u64 {
        try self.history_pending_buf.ensureTotalCapacity(self.gpa, self.history.items.len);
        self.history_pending_buf.clearRetainingCapacity();
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

    // ── frame ────────────────────────────────

    /// Render one frame into `w` (a std.Io.Writer-compatible writer —
    /// in production, the bounded output queue's staging writer).
    ///
    /// Frame flow: idle check (zero bytes) → envelope prologue (sync,
    /// cursor, autowrap) → retirement erase → strategy → postpaint CPR
    /// query when one is owed → envelope epilogue (sync, cursor) → commit
    /// the frame state. After the frame the cursor
    /// sits at the band bottom (column 1 of the last row), which is
    /// exactly the row the query asks about, so a reply needs no
    /// correction for the frame that asked it. Allocation failure occurs before output.
    /// Exception: a clipped width change stages only a prepaint CPR,
    /// waits silently for its reply, then resumes the normal frame flow.
    /// A writer error preserves the committed frame and queued payloads, but `w` may hold
    /// a prefix. Retry only after discarding that staging; direct terminal output needs
    /// explicit recovery. Internal reusable capacity and preparation state may change.
    pub fn render(self: *Region, w: anytype) !void {
        if (!self.opts.interactive) return self.renderPlain(w);

        const diff = if (self.height == 0) null else self.scanChanges();
        // A band's physical extent against the window it has to live in.
        // Past it, the band's own top row IS the window's first row.
        const covered = self.term_rows > 0 and
            @max(self.bandRows(), self.painted_rows) > self.term_rows;
        // A queued row is written ABOVE the band top, so a band that
        // covers the window has no row to write it on: `.physical` wins
        // the strategy choice and repaints the band WITHOUT writing it,
        // and `.ledger` — the only frame that could — cannot run at all.
        // So the queue WAITS, whole and in order, and the first frame
        // whose top is reachable again writes all of it. It is never
        // dropped, and a band whose cells did not change never repaints
        // itself against a row it cannot place: a tick that did would
        // strand another copy of the band and drift it down one row per
        // tick, forever, and deliver nothing.
        const flush = (self.append_queue.items.len > 0 or
            self.history.items.len > self.history_written) and !covered;
        const hide_wanted = self.cursor_wanted_hidden;
        const cursor_turn = hide_wanted != self.cursor_hidden;
        const release = self.height == 0 and self.painted_rows > 0;
        const retiring = self.retireDue();
        // Repaint an overflowing band only when its cells or extent change.
        // An idle tick or a cursor measurement must not strand another copy.
        const band_work = diff != null or self.width_dirty or self.height_dirty or flush;
        if (covered and band_work) self.physical_dirty = true;
        // Width reflow beside a physical clip can move the cursor above
        // the new last row. Measure before repainting: the postpaint
        // report cannot recover how many old prefix rows the walk lost.
        // Keep the old snapshot/extent untouched while this query waits.
        if (self.physical_dirty and self.width_dirty and !self.reach_known and
            self.painted_rows > 0)
        {
            if (!self.query_outstanding) {
                try emit.queryCursor(w);
                self.takeQuery();
            }
            return;
        }
        const changed = self.first_frame or self.width_dirty or self.height_dirty or
            flush or release or self.physical_dirty or (diff != null) or cursor_turn or retiring;
        // Nothing to say: an idle frame emits zero bytes, envelope
        // included. A released band is silent too — unless rows the band
        // gave up are back on the screen, which only an erase can clear.
        //
        // An owed measurement is work ONLY while the single query slot is
        // free. While a reply is in flight — and a geometry change made it
        // stale, so it will be discarded — there is nothing to ask and
        // nothing to draw, and a frame that emitted the envelope anyway
        // would do it again on every tick until a slow terminal answered.
        const owe_query = self.anchor_dirty and !self.query_outstanding;
        if (!owe_query and !changed) return;
        if (self.height == 0 and !release and !flush and !retiring and !owe_query) return;
        const strategy: Strategy = self.planStrategy(release, flush);
        const reclaimed = switch (strategy) {
            .diff, .height => self.reclaimableRows(),
            .resize => if (self.opts.resize_mode != .rebuild)
                self.reclaimableRows()
            else
                0,
            else => 0,
        };
        // Both prepare steps run BEFORE the first byte, and both are
        // rolled back to nothing on failure: the live snapshot, `prev`,
        // the dirty flags, the ownership ledger and the byte stream are
        // all exactly as they were — no half-written frame, no split
        // state, no geometry staged for rows nobody painted.
        try self.prepareLedger(strategy, diff);
        try self.prepareSnapshot();
        const tape_from = self.wide_tape.items.len;
        const null_from = self.null_tape.items.len;
        errdefer {
            self.wide_tape.shrinkRetainingCapacity(tape_from);
            self.null_tape.shrinkRetainingCapacity(null_from);
            self.pending_owned.clearRetainingCapacity();
            self.pending_rows = 0;
        }

        var f: Frame = .{
            // The frame walks the cursor from where the last one parked
            // it, with the window it is walking inside — every move it
            // emits charges a step on this row, in order. The same moves
            // extend the transform a reply still in flight is waiting
            // for, so a late answer lands on the row the cursor is really
            // at rather than the one it was asked about.
            .cursor = self.cursor_screen,
            .last_row = if (self.term_rows == 0) -1 else @intCast(self.term_rows - 1),
            .query_shift = self.query_shift,
            .query_low = self.query_low,
            .query_high = self.query_high,
        };

        // Envelope prologue: sync, cursor, autowrap.
        if (self.opts.sync_output) try emit.beginSync(w);
        if (hide_wanted and !self.cursor_hidden) {
            try emit.hideCursor(w);
            f.hide_cursor = true;
        }
        // A staged row can arrive after the terminal narrowed. Autowrap
        // preserves its source and matches the native reflow projection;
        // each following CR clears a full-width row's deferred wrap.
        try emit.autowrapOn(w);

        // Distant retired rows are erased in place. A visible retired
        // suffix touching the band is instead repainted as part of it;
        // neither operation can cross a committed row or a blank gap.
        try self.retireErased(w, &f, reclaimed);

        if (reclaimed > 0) {
            try self.paintReclaimed(w, &f, reclaimed);
        } else switch (strategy) {
            .first => try self.paintFirst(w, &f),
            .collapse => try self.paintCollapse(w, &f),
            .ledger => try self.paintLedger(w, &f),
            .physical => try self.paintPhysical(w, &f),
            .resize => try self.paintResize(w, &f, diff),
            .height => try self.paintHeight(w, &f, diff),
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

        // The query goes out AFTER the paint and the park, and only
        // when the single slot is free: the reply is untagged, so two
        // in flight would be indistinguishable. Asking here is what
        // makes the answer mean anything — a query fired before the
        // frame describes a cursor the frame is about to move.
        if (owe_query) {
            try emit.queryCursor(w);
            f.query = true;
        }

        // Envelope epilogue: sync and cursor restoration; autowrap stays on.
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
        // Ensure the session's expected terminal modes on teardown.
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
            var next: usize = 0;
            for (self.history.items[self.history_written..]) |b| {
                try writePlainAppends(w, self.append_queue.items[next..b.appends_before]);
                next = b.appends_before;
                for (b.rows) |row| try w.print("{s}\n", .{row});
            }
            try writePlainAppends(w, self.append_queue.items[next..]);
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

    fn writePlainAppends(w: anytype, items: []const Append) !void {
        for (items) |item| switch (item) {
            .line => |l| try w.print("{s}\n", .{l}),
            .text => |t| try w.print("{s}\n", .{t}),
        };
    }

    /// Frame selection (B3 matrix). Priority: first > collapse >
    /// physical height change > ledger flush > resize > height change >
    /// diff.
    ///
    /// A physical change outranks the flush because the ledger is
    /// written ABOVE the band top, and a top that has scrolled into
    /// scrollback is no row anything may write to: the frame re-bases
    /// the band first, and the flush follows onto the settled one.
    fn planStrategy(self: *const Region, release: bool, flush: bool) Strategy {
        if (self.first_frame) return .first;
        if (release) return .collapse;
        // A width change under a declared model is a `.resize` only while
        // the band is wholly REACHABLE. The moment a clip has put part of
        // it outside the viewport, physical safety wins in EVERY resize
        // mode — including `.rebuild`, whose own walk starts at the parked
        // cursor and would settle rows no cursor move can reach as
        // committed history. Those rows are the live band's own
        // uncommitted text, and a terminal that handed its scrollback back
        // would show the popup twice; `.physical` retires them instead,
        // which is the one outcome a later pull can take back.
        if (self.nativeReflow() and self.width_dirty and !self.physical_dirty) return .resize;
        if (self.physical_dirty) return .physical;
        if (flush) return .ledger;
        if (self.width_dirty) return .resize;
        if (self.height_dirty) return .height;
        return .diff;
    }

    // ── frame painters (no state mutation) ─────────────

    /// `first`: write the queued scrollback at the cursor (nothing is
    /// on screen yet, so there is no band to clear), reserve the band
    /// with CRLF and append all `height` rows without clearing. Ends at
    /// the band bottom.
    /// A pending replay claims the whole scrollback stream, so it is
    /// written ALONE: the queued appends it supersedes never reach the
    /// wire.
    fn paintFirst(self: *Region, w: anytype, f: *Frame) !void {
        // A release left the cursor on the last settled row, and that row
        // is transcript now, so rows written above the band start one
        // row below it. A frame with nothing to write above takes no
        // step and moves nothing: a plain re-create keeps the band's own
        // rows, exactly where the settled content ends.
        const written = self.writtenRows();
        if (self.released and written > 0) try self.stepOffSettledRow(w, f);
        try self.writeHistoryBatches(w, f);
        // `append_lines` governs the FIRST band only. A band re-created
        // after a release starts one row below the cursor, and that row
        // is settled content, so the reservation is mandatory: writing
        // in place would overwrite the transcript.
        if ((self.opts.append_lines or self.released) and self.height > 0) {
            // CRLF creates the band's rows below the cursor (scrolling at
            // the window's bottom), then CUU returns to the first of them.
            // The band occupies exactly the rows it reserved: painting
            // from the reserved bottom would leave `height - 1` blank rows
            // above the band and push it off its own reservation.
            try emit.appendLines(w, self.height);
            f.down(self.height);
            try self.moveToBandTop(w, f, self.height);
            // The run reaches from the ledger's nearest group to the band
            // top, which is where this frame left it, so it is recorded
            // as a run instead of a shift counter: every offset above it
            // is then a projection and cannot drift.
            //
            // A first band leaves the cursor's own row between it and
            // whatever was above: one blank row. A re-created band starts
            // directly below the settled row: the collapse settled the
            // cursor's own row as committed content with the footprint it
            // was painted with, and counting it here as a blank would give
            // the ledger two rows for one physical row. The rows this frame
            // wrote above the band are part of the same run and move it
            // down again, one for one.
            f.band_push = if (self.released)
                @as(u32, @intCast(written))
            else
                1;
        }
        var tracked: Style = .{};
        for (0..self.height) |y| {
            if (y > 0) try w.writeAll("\r\n") else try w.writeAll("\r");
            try self.writeRow(w, y, &tracked, false);
        }
        // One newline between every pair of rows, after the reservation
        // above it: the reservation moves the cursor to the band's own
        // top, this walk ends on its bottom.
        f.down(self.height -| 1);
        if (!tracked.eql(Style{})) try w.writeAll(emit.reset);
        try w.writeAll("\r");
        f.painted = self.height;
        f.high_water = self.height;
        f.clear_first = true;
        f.clear_width_dirty = true;
        f.clear_height_dirty = true;
        // Every row is written from scratch here, so a physical change
        // waiting behind this frame is settled by it.
        f.clear_physical = true;
    }

    /// `collapse`: the band reached height 0. The rows stay on screen as
    /// settled content — releasing a band never erases anything, and
    /// never touches the transcript. The cursor parks where it is, on
    /// the row that is now settled content; `commit` publishes the
    /// release, so a frame that dies while staging leaves the band
    /// strategy and the anchor coherent.
    ///
    /// Every row the band occupied hands the ledger over as COMMITTED
    /// content, not as blank padding: the band is gone but the screen
    /// still shows those strings, and a terminal that reflows or trims
    /// from the front has to be able to project them from the geometry
    /// alone once their text is freed.
    ///
    /// The cursor's OWN row settles with them, and with the footprint
    /// it was painted with. It is transcript the moment the band is
    /// gone, and the moment a band is re-created it becomes an ordinary
    /// NON-CURSOR group: a later column change repacks it from that
    /// geometry and may well make it taller. A ledger that called it
    /// blank would under-count the rows above the band by however much
    /// it grows, and every offset read off that ledger — the retirement
    /// walk above all — would then stop that much too low, on settled
    /// content the band never gave up.
    ///
    /// The rows a CLIP already took out of reach are the exception. A
    /// release is chosen before `physical_dirty` is consulted
    /// (`planStrategy` answers `.collapse` first), and a clip is exactly
    /// the state where the band is taller than the window: those rows are
    /// above the top no cursor move reaches, the screen is not showing
    /// them, and they are still the band's own uncommitted text.
    /// Settling one as committed would make it untouchable for ever — a
    /// terminal that hands its scrollback back would show the released
    /// band twice, and no erase could ever reach the copy. So the rows
    /// the window can still show settle as committed and the rows it
    /// cannot RETIRE, and the erase takes them back the moment the
    /// viewport reaches them.
    ///
    /// The frame asks nothing: a released band has no bottom row to ask
    /// about, and the next frame that re-creates one is the frame that
    /// asks (`setHeight`/`resize` mark the measurement owed).
    fn paintCollapse(self: *Region, w: anytype, f: *Frame) !void {
        try w.writeAll("\r");
        f.painted = 0;
        f.high_water = 0;
        f.clear_height_dirty = true;
        f.release = true;
        // The band owns no rows any more, so none of them can be
        // stranded by the screen having moved under it.
        f.clear_physical = true;
        // BAND ROWS, not physical rows: a ledger group is a hard logical
        // group, and each one keeps its own footprint — the cursor's own
        // row included, because it is settled transcript now and the
        // reservation that re-creates the band leaves it where it is.
        const settled = self.painted_rows;
        if (settled > 0) {
            const clip = self.clipped();
            f.ledger_out = .{
                .rows = settled,
                .retired_rows = @min(clip.rows, settled),
                .retired_chunks = clip.chunks,
                .settled = .committed,
            };
        }
    }

    /// `ledger`: write queued appends and unwritten ledger batches above
    /// the band, then repaint it (the band was erased). ED0 is anchored
    /// at the band top and never reaches above it. A pending replay
    /// claims the whole stream and supersedes the queued appends, which
    /// therefore never reach the wire.
    fn paintLedger(self: *Region, w: anytype, f: *Frame) !void {
        if (self.height > 0) {
            try self.moveToBandTop(w, f, self.painted_rows);
            try emit.eraseToEnd(w);
        } else {
            try self.stepOffSettledRow(w, f);
        }
        try self.writeHistoryBatches(w, f);
        if (self.height > 0) {
            // The rows above pushed the band down by their exact count;
            // each one is already staged in the ledger with its emitted
            // geometry, so the push needs no counter of its own.
            try self.paintAll(w, f);
        } else {
            try w.writeAll("\r");
        }
        // `paintAll` repainted every row at `height`, so the band
        // physically IS that size now: a height change pending beside
        // the flush is settled by this frame and must never reserve its
        // rows a second time.
        f.clear_height_dirty = true;
    }

    /// Start the rows a frame writes above the band ONE ROW BELOW the
    /// cursor while the band is released.
    ///
    /// A release settles the row the cursor parks on along with the rest
    /// of the band: it is transcript from that moment, with a geometry
    /// of its own, and the ledger owns it. So it is not free space — a
    /// stream that started on it would overwrite committed content and
    /// give the ledger two rows for one physical row, which is exactly
    /// the off-by-one that makes every offset above the band — and the
    /// retirement walk with it — aim a row group too low.
    ///
    /// A band that was never released has nothing settled there: the
    /// cursor's row is where the app left it, and the first frame, like
    /// every later one, writes on it.
    fn stepOffSettledRow(self: *const Region, w: anytype, f: *Frame) !void {
        if (!self.released) return;
        try w.writeAll("\r\n");
        f.down(1);
    }

    /// `resize`: a width change, painted according to
    /// `Options.resize_mode` (C2). In every mode the transcript above
    /// the band keeps its rows — a resize never rewrites committed
    /// history.
    ///
    /// Under a declared native model the band no longer occupies the
    /// number of rows it was composed with, so every walk here is
    /// measured against `bandRows()` — the committed geometry
    /// projected at the width the terminal has just repacked it to —
    /// and never against `painted_rows`. That is what keeps the
    /// band-top walk landing on the band's own first row instead of
    /// inside the reflowed rows above it.
    fn paintResize(self: *Region, w: anytype, f: *Frame, diff: ?RowRange) !void {
        const painted = self.bandRows();
        switch (self.opts.resize_mode) {
            .append => {
                // The anchor does not move: clear the band from its top
                // down (ED0, never above it) and repaint the band in
                // place.
                //
                // A repack can leave the OLD band taller than the one
                // the app just re-laid out, and those rows are the
                // band's own uncommitted text sitting below the new
                // band bottom — ED0 from the top never reaches them and
                // nothing above the band top may be touched. Clear
                // exactly those rows, row-scoped, on the way.
                // The walk is measured from wherever the settle left
                // the cursor, which is the new band bottom once it has
                // run and the old one while it has not.
                var walk = painted;
                if (painted > @as(u32, self.height)) {
                    try self.settleExtent(w, f);
                    walk = self.height;
                }
                if (self.height > 0) {
                    // Nothing is the band's to erase while it is
                    // released: the row the cursor parks on is settled
                    // transcript, and ED0 from it would wipe that.
                    try self.moveToBandTop(w, f, walk);
                    try emit.eraseToEnd(w);
                }
                try self.cur.renderAll(w);
                f.down(self.height -| 1);
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
                f.down(self.height -| 1);
                try w.writeAll("\r");
                // Everything above the old bottom stays on screen and
                // becomes the transcript's: those are the rows this
                // resize settles as history, and their geometry joins
                // the ledger so a later narrowing can still project
                // them after their text is freed.
                //
                // It is the OLD EXTENT above the cursor that settles —
                // E−1 physical rows, not `height - 1` logical ones. The
                // two are the same count for every band that fits, and
                // they part company the moment a declared model's band
                // row is several physical rows tall: `.rebuild` starts
                // painting ON the cursor's row, so the whole old extent
                // leaves the band and every chunk of the last row above
                // the cursor's own is settled history too. The cursor's
                // own row is the one chunk that is not: it is what this
                // very frame overwrote.
                if (self.painted_rows > 0) {
                    f.ledger_out = .{
                        .rows = self.painted_rows,
                        .retired_rows = 0,
                        .settled = .committed,
                        .settled_chunks = self.bandRowRows(@as(u32, self.painted_rows - 1)) -| 1,
                    };
                    // The band top moved DOWN to the old bottom. Nothing
                    // tracks that here: the anchor is derived from the
                    // cursor row this frame's own walk produced, and the
                    // CPR reply confirms it.
                }
            },
            .preserve => {
                // Row-scoped reflow: no ED0 anywhere, so nothing above
                // the band moves and a row the app did not re-lay out
                // is not even touched. Only the rows the reflow actually
                // changed are erased and repainted, each at its own band
                // row.
                //
                // This mode never clears the band, so a height change
                // arriving WITH the width change settles the extent
                // here — the rows the new height releases are erased,
                // the ones it gains reserved, exactly as the `height`
                // strategy does. `.append` and `.rebuild` settle it by
                // repainting instead, so neither reserves twice.
                try self.settleExtent(w, f);
                try self.moveToBandTop(w, f, self.height);
                if (self.nativeReflow()) {
                    // Reflow moved physical rows independently of cell damage.
                    try self.paintAll(w, f);
                } else {
                    try self.cur.renderDiff(&self.prev, w);
                    f.down(diffRows(diff));
                    const bottom: u16 = if (diff) |ch| @intCast(ch.last) else 0;
                    try self.parkAfter(w, f, bottom, self.height);
                }
            },
        }
        // Every mode ends on the band's own last row, and each of them
        // charged the walk that got it there in place.
        f.painted = self.height;
        f.high_water = self.height;
        f.clear_width_dirty = true;
        f.anchor_dirty = true;
        // Every mode repainted (or reserved) the band at `height`, so the
        // pending height change is settled here too.
        f.clear_height_dirty = true;
    }

    /// `physical`: the terminal's visible height changed under a band
    /// that occupies more rows than the new screen can reach. The rows
    /// that scrolled off are gone from the screen while `prev` still
    /// holds their text, so this frame repaints EVERY row the band
    /// survives instead of diffing one — a diff reads those rows as
    /// unchanged and strands whatever scrolled in behind them.
    ///
    /// The band re-bases on the CURSOR, whose hard row a shrink keeps.
    /// The walk reaches at most the band's projected extent or the
    /// measured rows through that cursor (`term_rows` while unmeasured).
    /// The erase
    /// that follows touches only rows the band owned, never a row above
    /// it: the transcript keeps its rows, the walk never reaches into
    /// scrollback, and a ledger that has grown above the band cannot
    /// turn a physical clip into a transcript erase.
    ///
    /// Under a declared native model `bandRows()` is a projection, not a
    /// row count: the band's committed geometry is packed at the width
    /// the terminal has just used, with the cursor's exempt group left at
    /// the one row it always is. Walking `painted_rows` instead would
    /// stop inside the reflowed rows and leave the repaint painting over
    /// the transcript.
    ///
    /// Rows the band gives up but the screen still shows are erased
    /// here; every row it keeps is repainted. The frame ends parked on
    /// the owned bottom, as every other frame does.
    fn paintPhysical(self: *const Region, w: anytype, f: *Frame) !void {
        // The re-base is about the BAND, never about the whole content
        // above it. `reachable` counts only rows the band owns, so the
        // walk up and the erases that follow can never reach a committed
        // row: a ledger that has grown above the band must not turn a
        // physical clip into a transcript erase. Without a declared
        // native model `band` IS `painted_rows`, so this is the walk the
        // file has always made.
        const reachable = self.reachableBandRows();
        try self.moveToBandTop(w, f, reachable);
        const released = reachable -| self.height;
        if (released > 0) {
            // The rows the band gives up and the screen still shows.
            var erased: u32 = 0;
            while (erased < released) : (erased += 1) {
                try emit.eraseLine(w);
                if (erased + 1 < released) try w.writeAll("\r\n");
            }
            try w.writeAll("\r\n"); // onto the row the band now starts at
            f.down(released);
        }
        try self.cur.renderAll(w);
        f.down(self.height -| 1);
        try w.writeAll("\r");
        f.painted = self.height;
        f.high_water = self.height;
        // The band was repainted at `height`, so a width or height
        // change that arrived beside this one is settled here too.
        f.clear_width_dirty = true;
        f.clear_height_dirty = true;
        f.clear_physical = true;
        // Every band row above the NEW band top has left the band, and
        // the new band top is the top of the WALK, not the old one:
        // `renderAll` starts there and paints `height` rows, so the band
        // is exactly the rows under the walk and nothing else. A band
        // that fits never moves — `reachable` is the whole extent, the
        // walk lands on the old top, and what leaves is what the app
        // shrank the band by. A band the screen cannot hold DOES move:
        // the rows the clip pushed out of reach keep the band's old text
        // on the band's old lines, the terminal scrolls the repaint
        // past them, and the band comes back one or more rows lower with
        // the old lines stranded above it and owned by nobody.
        //
        // That is what makes the clip a retirement. A taller window
        // hands the stranded rows back and nothing else would ever take
        // them, so the region has to be holding them already: they are
        // still the band's own uncommitted text. What the band gave up
        // and the screen still shows was erased above and is a hard
        // blank row, never retired.
        //
        // The count is in BAND rows, so the physical budget the walk
        // could not reach is walked into them with the producer's own
        // chunk counts, and a cut that falls inside a band row counts
        // that row once and hands over only the chunks above the cut.
        const clip = self.clipped();
        const leaving = clip.rows + @intFromBool(clip.chunks > 0);
        if (leaving > 0 or released > 0) {
            f.ledger_out = .{
                .rows = leaving,
                .retired_rows = clip.rows,
                .retired_chunks = clip.chunks,
                .erased_rows = released,
            };
        }
        f.anchor_dirty = true;
    }

    /// `height`: the band's height changed. Settle the physical extent
    /// — reserve the rows it gained, erase the tail it lost — then diff
    /// the band from the extent this frame settled on.
    ///
    /// The step is the NET difference from the extent already on screen,
    /// never one `setHeight` call's delta: a session may shrink and
    /// regrow a band between two renders (the REPL popup opens and
    /// closes inside one tick), and moving the terminal by the last
    /// delta would strand rows above the band that the band no longer
    /// owns and may therefore never erase.
    fn paintHeight(self: *Region, w: anytype, f: *Frame, diff: ?RowRange) !void {
        try self.settleExtent(w, f);
        f.painted = self.height;
        f.high_water = self.height;
        f.clear_height_dirty = true;
        if (diff) |ch| {
            // The walk above left the cursor on the band bottom this
            // frame settled, and erased every row the new high-water
            // mark no longer owns, so the diff settles from `height`.
            try self.paintDiff(w, f, ch, .{ .painted = self.height, .high_water = self.height });
        } else {
            // Extent-only frame: park at the new band bottom.
            try self.park(w);
        }
    }

    /// Make the band physically `height` rows: reserve the rows it
    /// gained with CRLF — a band row that does not exist on screen
    /// cannot be painted — or erase the tail it lost row-scoped,
    /// because EL touches only the cursor's own row and so never
    /// reaches content above the band. The cursor ends on the new band
    /// bottom.
    ///
    /// Entry: parked at the bottom of the extent the band occupies now,
    /// which is `bandRows()` — the committed geometry projected at the
    /// width the terminal actually has. Without a declared native model
    /// that is exactly `painted_rows`, which is why every caller is
    /// written against this one call. A run of height changes that
    /// settled back onto the extent on screen moves nothing at all, so
    /// this emits no bytes for them.
    fn settleExtent(self: *Region, w: anytype, f: *Frame) !void {
        const old = self.bandRows();
        const want: u32 = self.height;
        if (want > old) {
            const gained = want - old;
            try emit.appendLines(w, @intCast(gained));
            f.down(gained);
            // New rows belong inside the enlarged band. Its top, and every
            // ledger offset above it, remain on the same physical line.
        } else if (want < old) {
            const removed = old - want;
            try w.writeAll("\r");
            var erased: u32 = 0;
            while (erased < removed) : (erased += 1) {
                try emit.eraseLine(w);
                if (erased + 1 < removed) try w.writeAll("\x1b[1A");
            }
            try w.writeAll("\r");
            try w.writeAll("\x1b[1A"); // first released row -> new band bottom
            // One CUU between every pair of erased rows and one more to
            // the new band bottom: `removed` in all, not `removed + 1`.
            f.up(removed);
            // The band top did not move: the tail it released was
            // BELOW it, so nothing above the top shifts and the ledger
            // needs no row for them.
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
        try self.moveToBandTop(w, f, extent.painted);
        try self.cur.renderDiff(&self.prev, w);
        // `renderDiff` walks from the band's own top down to the last
        // changed row, one newline per band row it crossed.
        f.down(ch.last);
        var bottom_row: usize = ch.last;
        const content_len = self.contentLen();
        if (content_len < extent.high_water) {
            const hw = extent.high_water;
            const tail_start = @max(content_len, ch.last + 1);
            if (tail_start < hw) {
                try w.writeAll("\r");
                var down = tail_start - ch.last;
                f.down(down);
                while (down > 0) : (down -= 1) try w.writeByte('\n');
                var y = tail_start;
                while (y < hw) : (y += 1) {
                    try emit.eraseLine(w);
                    if (y + 1 < hw) try w.writeAll("\r\n");
                }
                f.down(hw - tail_start - 1);
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
        // Painting `height` rows walks down `height - 1` newlines.
        f.down(self.height -| 1);
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
        try w.writeAll("\r");
        if (painted == 0) return;
        var rest = painted - 1 - @min(bottom_row, painted - 1);
        f.down(rest);
        while (rest > 0) : (rest -= 1) try w.writeByte('\n');
    }

    // ── ledger bytes ──────────────────────────────

    /// Measure one caller-owned hard row and stage it in the ownership
    /// ledger as committed content. Nothing is copied and no glyph text
    /// is retained: the record is the emitted column count plus the
    /// positions of its width-2 glyphs on the region's one reused tape,
    /// and a row with no wide glyph appends no position at all.
    ///
    /// Measured through `markdown.Sanitizer`, the library's single
    /// escape machine, because caller text is untrusted and the columns
    /// the TERMINAL ends up with are the ones that survive the filter —
    /// a dropped escape body leaves no column behind, and a cluster the
    /// filter refuses contributes none either. Width comes from the
    /// shared seam, so a reflow projection of this row and of a band
    /// row written by `Buffer` cannot disagree.
    ///
    /// The source is bounded by the composed width: `.line` appends are
    /// hard-wrapped there, and exact-layout rows are supplied by the caller.
    /// Output enables DECAWM to preserve that source if the terminal narrows
    /// before receiving it. The declared native model then projects this
    /// footprint at the observed width, including those soft wraps.
    fn stageTextRow(self: *Region, san: *markdown.Sanitizer, text: []const u8) !void {
        // Without a declared native model nothing ever reads this
        // geometry: the row is one physical row whatever its columns
        // are. Recording it anyway would spend a grapheme walk, a tape
        // slot and a sanitizer pass on every transcript row of every
        // session that never repacks — so the ledger records the ROW and
        // leaves the projection to the model that needs one.
        if (!self.nativeReflow()) {
            try self.pending_owned.append(self.gpa, .{ .kind = .committed });
            self.pending_rows += 1;
            return;
        }
        const start = self.wide_tape.items.len;
        errdefer self.wide_tape.shrinkRetainingCapacity(start);
        const cols: u32 = self.width;
        var col: u32 = 0;
        var off: usize = 0;
        while (off < text.len) {
            const len = Width.firstCellLen(text[off..]);
            if (len == 0) break;
            const gc = text[off .. off + len];
            off += len;
            if (!san.acceptCluster(gc)) continue;
            const wg = Width.graphemeWidth(gc);
            if (wg <= 0) continue;
            // Exact-layout sources must fit the composed width; keep their
            // footprint bounded by it, like the line-wrapping producer.
            if (col + @as(u32, @intCast(wg)) > cols) break;
            if (wg >= 2) try self.wide_tape.append(self.gpa, @intCast(col));
            col += if (wg >= 2) 2 else 1;
        }
        const fp: Buffer.RowFootprint = .{
            .columns = @intCast(col),
            .wide_start = start,
            .wide_count = self.wide_tape.items.len - start,
        };
        try self.pending_owned.append(self.gpa, .{
            .fp = fp,
            .kind = .committed,
            // How tall the terminal makes this row at the width it is
            // being written at, which is what the margin above already
            // made it: no column of the screen exists past it.
            .rows = fp.rowsAt(self.wide_tape.items, self.width),
        });
        self.pending_rows += 1;
    }

    /// Stage one ledger batch's rows: each is written verbatim as
    /// exactly one hard row, so each is measured on its own.
    fn stageRows(self: *Region, san: *markdown.Sanitizer, rows: []const []const u8) !void {
        for (rows) |row| try self.stageTextRow(san, row);
    }

    /// Allocation-free hard rows of a line append, shared by reservation
    /// counting and emission so a retry and its ledger cannot disagree.
    const LineRows = struct {
        segments: std.mem.SplitIterator(u8, .scalar),
        remaining: ?[]const u8 = null,
        width: u16,
        trailing: bool,
        /// The escape filter the terminal-visible width is measured
        /// through: a styled line's SGR bytes take no column, so they
        /// must not shorten its rows, and a row never ends inside one.
        san: markdown.Sanitizer = .{},

        fn init(text: []const u8, columns: u16) LineRows {
            return .{
                .segments = std.mem.splitScalar(u8, text, '\n'),
                .width = columns,
                .trailing = std.mem.endsWith(u8, text, "\n"),
            };
        }

        fn next(self: *LineRows) ?[]const u8 {
            const segment = self.remaining orelse blk: {
                const seg = self.segments.next() orelse return null;
                // A final LF already terminates its preceding hard row.
                if (seg.len == 0 and self.segments.index == null and self.trailing) return null;
                break :blk seg;
            };
            // Walk cell clusters through the filter: escape bytes and
            // zero-width clusters ride along in the current row, and the
            // row ends before the first visible cluster that would
            // overflow it.
            var len: usize = 0;
            var col: usize = 0;
            while (len < segment.len) {
                const n = Width.firstCellLen(segment[len..]);
                if (n == 0) break;
                const gc = segment[len .. len + n];
                var trial = self.san;
                const visible = trial.acceptCluster(gc);
                const wg = if (visible) Width.graphemeWidth(gc) else 0;
                const cells: usize = if (wg > 0) @intCast(wg) else 0;
                // A cluster wider than the whole band cannot be split.
                // Consume it alone, even at width zero, rather than
                // stalling the iterator.
                if (cells > 0 and col + cells > self.width and col > 0) break;
                self.san = trial;
                len += n;
                col += cells;
                if (cells > 0 and col >= self.width) {
                    // Keep trailing escapes (an SGR reset) on this row.
                    while (len < segment.len) {
                        const m = Width.firstCellLen(segment[len..]);
                        if (m == 0) break;
                        var tail = self.san;
                        const tail_gc = segment[len .. len + m];
                        if (tail.acceptCluster(tail_gc) and Width.graphemeWidth(tail_gc) > 0) break;
                        self.san = tail;
                        len += m;
                    }
                    break;
                }
            }
            self.remaining = if (len < segment.len) segment[len..] else null;
            return segment[0..len];
        }
    };

    /// Emit this submission-order slice of appends. Lines hard-wrap on cell
    /// boundaries; text retains its caller-supplied row layout. Every CRLF
    /// stages one ownership entry and charges one cursor move.
    fn writeAppends(self: *Region, w: anytype, f: *Frame, items: []const Append) !void {
        var san: markdown.Sanitizer = .{};
        for (items) |item| {
            switch (item) {
                .line => |l| {
                    var rows = LineRows.init(l, self.width);
                    while (rows.next()) |row| {
                        try self.stageTextRow(&san, row);
                        try w.writeAll(row);
                        try w.writeAll("\r\n");
                        f.down(1);
                    }
                },
                .text => |t| {
                    const trailing = std.mem.endsWith(u8, t, "\n");
                    const segments = std.mem.count(u8, t, "\n") + 1;
                    var it = std.mem.splitScalar(u8, t, '\n');
                    var first_seg = true;
                    var seen: usize = 0;
                    while (it.next()) |seg| {
                        seen += 1;
                        if (!first_seg) try w.writeAll("\r\n");
                        first_seg = false;
                        // One hard row per segment, except the empty one
                        // a trailing newline produces: the `\r\n` that
                        // newline already wrote IS the row move, so
                        // staging it would put a blank row in the ledger
                        // that no byte ever created — and a phantom row
                        // above the band pushes every offset under it.
                        if (!(seen == segments and trailing)) {
                            try self.stageTextRow(&san, seg);
                        }
                        try w.writeAll(seg);
                    }
                    if (!std.mem.endsWith(u8, t, "\n")) try w.writeAll("\r\n");
                    // Each `\n` became a hard `\r\n`, and an item that
                    // does not end in one gets the terminator anyway:
                    // that is how many rows the band top just dropped
                    // past. `anchor_dirty` still stands — the ROWS this
                    // text occupies are the caller's to get right.
                    const moves: u32 = @intCast(
                        std.mem.count(u8, t, "\n") +
                            @as(usize, @intFromBool(!std.mem.endsWith(u8, t, "\n"))),
                    );
                    f.down(moves);
                    f.anchor_dirty = true;
                },
            }
        }
        f.took_appends = true;
    }

    /// Merge queued appends and retained batches in submission order.
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
    /// Every row written here is measured into the ownership ledger too,
    /// which is what lets the transcript keep its geometry once its text
    /// is acknowledged and freed.
    ///
    /// `f.replay` records the index `commit` supersedes from;
    /// `f.took_appends` drops the queue the replay replaces.
    fn writeHistoryBatches(self: *Region, w: anytype, f: *Frame) !void {
        var san: markdown.Sanitizer = .{};
        if (self.pendingReplay()) |at| {
            try self.stageRows(&san, self.history.items[at].rows);
            const rows = try writeRows(self.history.items[at].rows, w);
            // One hard row each, CRLF terminated: the band top drops
            // past them by exactly their count.
            f.down(rows);
            f.replay = at;
            f.took_appends = true;
            return;
        }
        // The write cursor only advances on commit: a frame that fails
        // mid-ledger must leave every batch unwritten.
        var next: usize = 0;
        for (self.history.items[self.history_written..]) |b| {
            try self.writeAppends(w, f, self.append_queue.items[next..b.appends_before]);
            next = b.appends_before;
            try self.stageRows(&san, b.rows);
            f.down(try writeRows(b.rows, w));
        }
        try self.writeAppends(w, f, self.append_queue.items[next..]);
        f.took_history = true;
    }

    /// Band rows a `renderDiff` walk crosses to reach its last changed
    /// row: one newline per row, counted from the band's own top. An
    /// empty diff crosses nothing.
    fn diffRows(diff: ?RowRange) u16 {
        const ch = diff orelse return 0;
        return @intCast(ch.last);
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

    // ── ownership ledger ─────────────────────────

    /// One ledger group addressed by its offset above the band top:
    /// offset 0 is the band top row itself, offset `k` the `k` rows
    /// above it.
    const At = struct { offset: u32, rows: u32 };

    /// The nearest retired group within the measured reach, skipping
    /// committed rows and blank gaps without changing their offsets.
    ///
    /// The ledger is stored earliest-first on purpose — a band-top shift
    /// is a change at its tail and a terminal front-trim a change at its
    /// head — so this is the reverse walk that turns it back into screen
    /// order, and `rows` is the group's projection at the width the
    /// terminal actually has. Nothing here consults a CPR reply beyond
    /// the row that reply established: an unmeasured reach reaches
    /// nothing, and no erase may run on a guess.
    fn nearestRetired(self: *const Region) ?At {
        if (!self.reach_known) return null;
        const ceiling = self.reach();
        if (ceiling < 1) return null;
        var offset: u32 = 1;
        var i = self.owned.items.len;
        while (i > 0) {
            i -= 1;
            const rows = self.groupRows(self.owned.items[i]);
            if (@as(i64, ceiling) < @as(i64, offset)) break;
            if (self.owned.items[i].kind == .retired) {
                const room = @min(rows, @as(u32, @intCast(ceiling)) - offset + 1);
                return .{ .offset = offset, .rows = room };
            }
            offset += rows;
        }
        return null;
    }

    /// Only the contiguous retired suffix belongs to the band's old
    /// prefix. CPR bounds the rows that can actually be taken back.
    fn reclaimableRows(self: *const Region) u32 {
        if (!self.reach_known or self.height == 0 or self.painted_rows == 0) return 0;
        if (self.bandRows() > self.term_rows or self.height > self.term_rows) return 0;
        const ceiling = self.reach();
        if (ceiling < 1) return 0;
        var rows: u32 = 0;
        var i = self.owned.items.len;
        while (i > 0 and rows < @as(u32, @intCast(ceiling))) {
            i -= 1;
            const g = self.owned.items[i];
            if (g.kind != .retired) break;
            rows += @min(self.groupRows(g), @as(u32, @intCast(ceiling)) - rows);
        }
        return rows;
    }

    /// Repaint from the measured returned prefix, then erase the old
    /// bottom's unused tail and park on the new bottom. No rows outside
    /// the union of the retired prefix and the old/live band are erased.
    fn paintReclaimed(self: *const Region, w: anytype, f: *Frame, rows: u32) !void {
        const old = self.bandRows() + rows;
        try self.moveToBandTop(w, f, old);
        try self.cur.renderAll(w);
        f.down(self.height -| 1);
        const tail = old -| self.height;
        if (tail > 0) {
            for (0..tail) |_| {
                try w.writeAll("\r\n");
                f.down(1);
                try emit.eraseLine(w);
            }
            try w.print("\x1b[{d}A", .{tail});
            f.up(tail);
        }
        try w.writeAll("\r");
        f.painted = self.height;
        f.high_water = self.height;
        f.reclaimed = rows;
        f.clear_width_dirty = true;
        f.clear_height_dirty = true;
    }

    /// Whether a measured retired row is owed reclamation or erasure.
    fn retireDue(self: *const Region) bool {
        return self.nearestRetired() != null;
    }

    /// Reserve every ledger entry, width-2 position and unprinted-gap
    /// interval this frame may add, before its first byte: a frame that
    /// dies staging leaves the committed ledger exactly as it was and the
    /// retry finds the same room. The only fallible ledger step of a
    /// frame, and it runs before `prepareSnapshot` can have published
    /// anything either.
    fn prepareLedger(self: *Region, strategy: Strategy, diff: ?RowRange) error{OutOfMemory}!void {
        self.pending_owned.clearRetainingCapacity();
        self.pending_band.clearRetainingCapacity();
        self.pending_rows = 0;
        // Only a re-base and a rebuild move the band's own rows into the
        // ledger; nothing else can. Their geometry is already recorded,
        // so their share of the tapes is copied, not re-measured.
        const hand_over: usize = switch (strategy) {
            .physical => blk: {
                const clip = self.clipped();
                break :blk clip.rows + @intFromBool(clip.chunks > 0);
            },
            .resize, .collapse => self.painted_rows,
            else => 0,
        };
        // Rows written above the band, rows handed over, one blank run
        // for a reservation, and one blank run per retired group an
        // erase splits.
        const writing = strategy == .first or strategy == .ledger;
        const written = if (writing) self.writtenRows() else 0;
        const entries = hand_over + written + self.owned.items.len + 2;
        try self.owned.ensureUnusedCapacity(self.gpa, entries);
        try self.pending_owned.ensureTotalCapacity(self.gpa, entries);
        if (!self.nativeReflow()) return;
        try self.pending_band.ensureTotalCapacity(self.gpa, self.cur.height);
        try self.band_fp.ensureTotalCapacity(self.gpa, @as(usize, self.cur.height) + 1);
        // Old hand-over sources can be much wider than the new grid.
        // Reserve their actual tape spans, not a bound from the new width.
        var handed_wide: usize = 0;
        var handed_gaps: usize = 0;
        const copied = self.band_fp.items[0..@min(hand_over, self.band_fp.items.len)];
        for (copied) |row| {
            if (row.rows == 0) continue;
            handed_wide += row.fp.wide_count;
            handed_gaps += row.fp.null_count;
        }
        const emitted_room = (@as(usize, self.cur.width) / 2 + 1) * written;
        try self.wide_tape.ensureUnusedCapacity(
            self.gpa,
            emitted_room + handed_wide,
        );
        try self.null_tape.ensureUnusedCapacity(
            self.gpa,
            emitted_room + handed_gaps,
        );
        // The band's geometry is what the NEXT native projection reads,
        // so it is (re)captured exactly when this frame paints it: a
        // frame that changes no cell and no geometry leaves the committed
        // footprints standing untouched. It is STAGED here and published
        // only at commit — the repack of an external width change is not
        // this frame's to do: `resize` already accounted that
        // transition, once, whether or not a frame ever ran for it.
        //
        // The declared model is what the capture is FOR, and the early
        // return above is what gates it: without one the footprints are
        // read by nothing, since `bandRows` answers `painted_rows` and a
        // re-base repacks at the width the band was just painted at. The
        // capture walks every cell of every band row and can allocate, so
        // running it for a session that never repacks would buy a dead
        // copy of the band and a per-frame grapheme walk in exchange for
        // a record nothing will ever read.
        if (strategy != .diff or diff != null) try self.captureBand();
    }

    /// Rows the ledger bytes of the frame in flight will write above the
    /// band: the queued appends (or the replay that supersedes them) and
    /// the unwritten batches. Counted before the first byte so their
    /// geometry has tape room. Lines use the emission iterator; a `.text`'s
    /// internal newlines are hard row moves, exactly as `writeAppends` writes them.
    fn writtenRows(self: *const Region) usize {
        if (self.pendingReplay()) |at| return self.history.items[at].rows.len;
        var n: usize = 0;
        for (self.append_queue.items) |item| switch (item) {
            .line => |l| {
                var rows = LineRows.init(l, self.width);
                while (rows.next() != null) n += 1;
            },
            .text => |t| n += std.mem.count(u8, t, "\n") +
                @intFromBool(!std.mem.endsWith(u8, t, "\n")),
        };
        for (self.history.items[self.history_written..]) |b| n += b.rows.len;
        return n;
    }

    /// Record what `writeRow` would put on the wire for every band row
    /// of the frame in flight. Read from `cur` before the first byte, so
    /// the geometry and the published snapshot cannot disagree, and
    /// staged in `pending_band` so a failed frame changes nothing.
    ///
    /// The record stored is the PROJECTION form: the physical chunk
    /// count it has right now is one row per band row (the frame composed
    /// them at this very width), and what a later reflow needs is how
    /// many columns are actually painted — trailing unprinted stretches
    /// are trimmed here so the next packing does not reflow a row that was
    /// never printed.
    ///
    /// The unprinted intervals are carried through, not dropped: a band
    /// row that spans a wide stretch and a row that merely left it blank
    /// have the same columns and the same width-2 positions, and only the
    /// intervals tell the next repack which is which.
    fn captureBand(self: *Region) error{OutOfMemory}!void {
        self.band_next.clearRetainingCapacity();
        self.band_next_gaps.clearRetainingCapacity();
        for (0..self.cur.height) |y| {
            const fp = try self.cur.rowFootprint(
                self.gpa,
                @intCast(y),
                &self.band_next,
                &self.band_next_gaps,
            );
            self.pending_band.appendAssumeCapacity(.{ .fp = .{
                .columns = fp.paintedPrefixColumns(self.band_next_gaps.items, fp.columns),
                .wide_start = fp.wide_start,
                .wide_count = fp.wide_count,
                .null_start = fp.null_start,
                .null_count = fp.null_count,
            } });
        }
    }

    /// Erase visible retired rows outside the contiguous prefix this
    /// frame reclaims. All movement is bounded by the measured reach.
    ///
    /// Entry: the cursor parked on the band bottom, where every frame
    /// starts. A group at `offset` is `cursor_off + offset` rows above
    /// that, and only rows the reach actually covers are walked to, so
    /// the walk never asks for a row the terminal cannot reach and never
    /// lands on one it did not mean to. That is the whole safety
    /// argument: a CUU past the viewport top would clamp onto a
    /// COMMITTED row and erase it, which is why an unreachable group
    /// stays tracked rather than guessed at, and why a frame whose reach
    /// is not measured emits no erase at all — it renders the live band
    /// relatively and the postpaint query measures it afterwards.
    fn retireErased(self: *const Region, w: anytype, f: *Frame, reclaimed: u32) !void {
        if (!self.reach_known) return;
        const ceiling = self.reach();
        if (ceiling < 1) return;
        var walked: u32 = 0;
        var offset: u32 = 1;
        var i = self.owned.items.len;
        while (i > 0) {
            i -= 1;
            const g = self.owned.items[i];
            const rows = self.groupRows(g);
            // Everything further up is further out of reach, so the walk
            // ends here and no row above it is even considered.
            if (@as(i64, ceiling) < @as(i64, offset)) break;
            const first = @max(offset, reclaimed + 1);
            const end = @min(offset + rows, @as(u32, @intCast(ceiling)) + 1);
            if (g.kind == .retired and first < end) {
                const room = end - first;
                const lowest = @as(u32, @intCast(@max(self.cursor_off, 0))) + first;
                if (lowest > walked) {
                    const step = lowest - walked;
                    try w.print("\x1b[{d}A", .{step});
                    f.up(step);
                }
                var done: u32 = 0;
                while (done < room) : (done += 1) {
                    try emit.eraseLine(w);
                    if (done + 1 < room) {
                        try w.writeAll("\x1b[1A");
                        f.up(1);
                    }
                }
                walked = lowest + room - 1;
            }
            offset += rows;
        }
        if (walked == 0) return;
        // CUD, never LF: walking back down to the band bottom must not
        // scroll a screen the painter is about to use.
        try w.print("\x1b[{d}B", .{walked});
        f.down(walked);
        try w.writeAll("\r");
    }

    /// Settle exactly the visible retirements this frame erased or
    /// reclaimed. Keep distant blank gaps in place; a partial cleanup
    /// leaves its surviving prefix with the original source geometry.
    ///
    /// Runs from `commit` before the frame's extent or cursor row move,
    /// off the same state the walk used, so it is exact: a frame that
    /// died staging its bytes never gets here and keeps the whole ledger
    /// for the retry.
    fn retireLedger(self: *Region) void {
        if (!self.reach_known) return;
        const ceiling = self.reach();
        if (ceiling < 1) return;
        var offset: u32 = 1;
        var i = self.owned.items.len;
        while (i > 0) {
            i -= 1;
            const g = self.owned.items[i];
            const rows = self.groupRows(g);
            if (@as(i64, ceiling) < @as(i64, offset)) break;
            if (g.kind == .retired) {
                const erased = @min(rows, @as(u32, @intCast(ceiling)) - offset + 1);
                self.ledger_dirty = true;
                if (erased == rows) {
                    self.owned.items[i] = .{ .kind = .blank, .rows = rows };
                } else {
                    // The surviving prefix is above the erased suffix.
                    self.owned.items[i] = self.suffixOf(g, rows - erased);
                    self.owned.insertAssumeCapacity(
                        i + 1,
                        .{ .kind = .blank, .rows = erased },
                    );
                }
            }
            offset += rows;
        }
    }

    /// The part of a retired group that survives erasing its nearest
    /// `keep_rows` physical rows — the chunks the screen did not show.
    ///
    /// The producer's `prefixRows` is the physical cut projection: it
    /// keeps the SAME logical origin and the SAME recorded width-2
    /// positions and takes whole chunks, so the cut is exact at the glyph
    /// boundary with no padding folded in. The surviving SOURCE then
    /// follows the same flatten rule as any other geometry event
    /// (`flatten`): the non-final chunks it kept count full, and only the
    /// last one's unprinted tail is walked back. That is what separates
    /// a surviving printed prefix — which must go on reflowing to many
    /// rows as the window narrows — from a surviving prefix that was
    /// never printed at all, which stays the one blank row it is.
    ///
    /// The physical chunk count is kept verbatim. The terminal has
    /// repacked nothing yet, so the screen is still showing exactly
    /// `keep_rows` rows, and the trimmed source is what the NEXT geometry
    /// event packs from.
    ///
    /// Under `.none` there is nothing to cut — every group is one
    /// physical row — so only the kind survives.
    fn suffixOf(self: *const Region, g: Owned, keep_rows: u32) Owned {
        if (!self.nativeReflow() or g.kind == .blank) {
            return .{ .kind = g.kind, .rows = @max(keep_rows, 1) };
        }
        if (keep_rows == 0) return .{ .kind = .blank, .rows = 1 };
        // The cut is taken on the RECORD's own row count, and the
        // source is only re-cut when a real chunk boundary falls inside
        // it. A group whose last chunk was trimmed to nothing still
        // occupies the rows the screen is showing, and measuring the
        // cut from a recomputed packing would keep the whole source for
        // a suffix that took its nearest rows off — over-stating the
        // survivor by exactly the rows the erase removed.
        if (keep_rows >= g.rows) {
            return .{ .fp = g.fp, .kind = g.kind, .rows = keep_rows };
        }
        const cut = g.fp.prefixRows(self.wide_tape.items, self.width, keep_rows);
        return .{
            .fp = .{
                .columns = flatten(
                    cut,
                    self.wide_tape.items,
                    self.null_tape.items,
                    self.width,
                    keep_rows,
                ),
                .wide_start = cut.wide_start,
                .wide_count = cut.wide_count,
                .null_start = cut.null_start,
                .null_count = cut.null_count,
            },
            .kind = g.kind,
            .rows = keep_rows,
        };
    }

    /// Lines of the terminal's buffer the Region accounts for, and lines
    /// it can account for under the declared profile. The band term is
    /// its PROJECTED extent, not `painted_rows`: the terminal repacks
    /// every band row but the cursor's own, and that group is left at the
    /// single row it always has.
    fn bufferLines(self: *const Region) u32 {
        return self.ownedRows() + @max(self.bandRows(), 1);
    }

    /// The declared `scrollback_rows` above the screen plus the
    /// `term_rows` it shows: the length of the buffer SUFFIX a terminal
    /// under this model keeps. The screen shows the LAST lines, so the
    /// unused rows under the cursor are inside this budget rather than
    /// beside it; see `trimToCapacity`.
    fn retainedLines(self: *const Region) u64 {
        return @as(u64, self.scrollbackCapacity()) + self.term_rows;
    }

    /// Apply the declared capacity: lines the terminal has DISCARDED from
    /// the front of its buffer, as opposed to merely hidden.
    ///
    ///     discarded = max(0, bufferLines - retainedLines)
    ///
    /// with `bufferLines` the Region's own lines — the ledger's rows
    /// above the band top plus the band's PROJECTED extent — and
    /// `retainedLines` the declared scrollback plus the reported
    /// viewport. A taller window hands its scrollback back and every
    /// hidden line comes back, so a hidden line is never in the count; a
    /// repack that pushed more lines above the screen than the
    /// declaration keeps is GONE, and an offset derived from a line that
    /// no longer exists would aim every later erase at the wrong row,
    /// which is committed content.
    ///
    /// This asks nothing of a cursor row, and that is what the DECLARED
    /// profile buys. `.non_cursor_rows` says the Region is the last
    /// thing the caller writes: the lines below the line its cursor is
    /// parked on are UNUSED — a hard blank the terminal appended under a
    /// window taller than the content, never a foreign wrapped group.
    /// Write `S` for `bufferLines`, `K` for `retainedLines`, and `B` for
    /// those unused lines. Then the count is exact, and it needs no
    /// carried scalar:
    ///
    /// - A repack rewrites every hard logical group that is not the
    ///   cursor's, so a narrowing GROWS every non-cursor group and a
    ///   widening shrinks them. An unused line is not a group at all —
    ///   no text, no wrap flag — so a repack never reflows one, but a
    ///   narrowing does PUSH the content above it up, which is where
    ///   `B` goes: down at a narrowing, back at a widening, as
    ///   cursorY 1 -> 3 -> 1 over one 131-column group at 131 -> 55 ->
    ///   131 columns measures.
    /// - The growth is therefore spent on `B` FIRST. Once `S > K` the
    ///   unused tail is necessarily exhausted — `S + B <= K` held before,
    ///   and the growth has already taken it — so the retained suffix
    ///   budget is exceeded by exactly `S - K` of the Region's own lines
    ///   and the trim is `S - K`. While `S <= K` there is no owned front
    ///   loss at all: the budget still covers `S + B`, and the blank
    ///   consumption a narrowing does is what took `S` there.
    /// - Widening cannot newly front-trim: it only lowers `S`.
    /// - The opaque prefix above the Region's own — content it never
    ///   wrote and cannot describe — moves monotonically in the same
    ///   direction, so it can absorb blanks or give rows back, but it
    ///   cannot make the retained suffix hold less than `K` lines of the
    ///   Region's own.
    ///
    /// Every observed width is accounted on its own against that `K`,
    /// which is what makes a coalesced burst irreversible step by step
    /// rather than once at its end: a line dropped at the narrowest width
    /// cannot come back at the next one, and the geometry the next
    /// packing reads is the geometry that is left.
    ///
    /// Nothing here is a claim about a caller that breaks the profile. A
    /// PRINTED line below the band is a hard logical group of its own: it
    /// reflows with everything else, and the same capacity, the same
    /// geometry and the same CPR replies then produce different buffer
    /// prefixes depending on it, so no count derived from here can say
    /// which of its lines the terminal kept. That caller declares
    /// `.none`. The declaration is the whole contract and nothing
    /// detects, probes or infers it.
    ///
    /// A trim only ever removes whole groups from the front plus a
    /// prefix of one boundary group, because that is the only order a
    /// terminal's buffer can lose them in.
    fn trimToCapacity(self: *Region) void {
        // Without a declared model there is no capacity to enforce, and
        // without a reported viewport there is no buffer to measure it
        // against: keep everything, which is the safe side.
        if (!self.nativeReflow() or self.term_rows == 0) return;
        const held = self.bufferLines();
        const keepable = self.retainedLines();
        if (held <= keepable) return;
        var excess: u32 = @intCast(@as(u64, held) - keepable);
        var drop: usize = 0;
        while (drop < self.owned.items.len and excess > 0) {
            const g = self.owned.items[drop];
            if (g.rows <= excess) {
                excess -= g.rows;
                drop += 1;
                continue;
            }
            // Rebase only the boundary group's surviving source. Each
            // group owns its tape spans, so the update needs no allocation.
            self.owned.items[drop] = self.headTrim(
                g,
                g.rows - excess,
                &self.wide_tape,
                &self.null_tape,
            );
            self.ledger_dirty = true;
            excess = 0;
            break;
        }
        if (drop > 0) {
            self.owned.replaceRangeAssumeCapacity(0, drop, &.{});
            self.ledger_dirty = true;
        }
        // Capacity applies to the live band too. Keep logical indices:
        // a discarded row contributes no source to any later hand-over.
        for (self.band_fp.items) |*row| {
            if (excess == 0) break;
            if (row.rows <= excess) {
                excess -= row.rows;
                row.rows = 0;
                continue;
            }
            const kept = self.headTrim(
                .{ .fp = row.fp, .rows = row.rows },
                row.rows - excess,
                &self.band_tape,
                &self.band_gaps,
            );
            row.* = .{ .fp = kept.fp, .rows = kept.rows };
            excess = 0;
            break;
        }
        std.debug.assert(excess == 0);
    }

    /// What survives a terminal dropping the first `head` physical rows
    /// of a group: the later chunks, with the logical columns they cover
    /// REBASED onto zero and the width-2 positions and unprinted
    /// intervals that go with them.
    ///
    /// The dropped head ends on a whole chunk boundary — the producer's
    /// `prefixRows` cuts whole glyphs and leaves an odd width's padding
    /// out of it — so the survivor's origin is exact, not an estimate.
    /// An unprinted interval that CROSSES the cut is intersected on both
    /// ends rather than dropped: it is still unprinted where it
    /// survives, and forgetting it would make a blank stretch reflow as
    /// if it had been painted. The intervals a full non-final chunk
    /// covers survive whole for the same reason its columns do: the
    /// terminal counts every non-final chunk full and trims only the
    /// last one's unprinted tail, and a survivor that lost its blank
    /// stretches would be packed as painted text the screen never had.
    ///
    /// `g.rows` is the authority on how tall the group is, never a
    /// recomputation from `g.fp`: a flatten or a suffix cut has already
    /// trimmed this source's logical tail, and packing the trimmed
    /// source again answers with FEWER rows than the terminal is
    /// showing. Taking the head off a count that is one too small either
    /// drops the whole survivor for a row of it, or shortens the ledger
    /// by rows that are still on the screen — and every offset above the
    /// band top is a projection from that ledger, so a short ledger
    /// aims the next retirement erase at committed content.
    fn headTrim(
        self: *const Region,
        g: Owned,
        keep_rows: u32,
        wide: *std.ArrayList(u16),
        gaps: *std.ArrayList(Buffer.RowFootprint.NullGap),
    ) Owned {
        if (g.kind == .blank) return .{ .kind = .blank, .rows = @max(keep_rows, 1) };
        if (!self.nativeReflow()) return .{ .kind = g.kind, .rows = @max(keep_rows, 1) };
        if (keep_rows == 0) return .{ .kind = .blank, .rows = 1 };
        if (keep_rows >= g.rows) return g;
        const drop_cols = g.fp.prefixRows(wide.items, self.width, g.rows - keep_rows).columns;
        if (drop_cols >= g.fp.columns) return .{ .kind = .blank, .rows = keep_rows };
        const painted = flatten(g.fp, wide.items, gaps.items, self.width, g.rows);

        // Each source owns its spans. Discard their head and rebase the
        // surviving positions in place; no other group reads these cells.
        var wide_start = g.fp.wide_start;
        var wide_end = wide_start + g.fp.wide_count;
        while (wide_start < wide_end and wide.items[wide_start] < drop_cols) wide_start += 1;
        while (wide_end > wide_start and wide.items[wide_end - 1] >= painted) wide_end -= 1;
        for (wide.items[wide_start..wide_end]) |*col| col.* -= drop_cols;

        var null_end = g.fp.null_start;
        for (gaps.items[g.fp.null_start..][0..g.fp.null_count]) |gap| {
            const lo = @max(gap.start, drop_cols);
            const hi = @min(gap.end, painted);
            if (lo >= hi) continue;
            gaps.items[null_end] = .{ .start = lo - drop_cols, .end = hi - drop_cols };
            null_end += 1;
        }
        return .{
            .fp = .{
                .columns = painted -| drop_cols,
                .wide_start = wide_start,
                .wide_count = wide_end - wide_start,
                .null_start = g.fp.null_start,
                .null_count = null_end - g.fp.null_start,
            },
            .kind = g.kind,
            .rows = keep_rows,
        };
    }

    /// Index of the earliest retirement obligation. Earlier groups are
    /// irrelevant to every remaining erase because offsets start at the tail.
    ///
    /// From that index on, EVERYTHING stays, gaps included. A retired
    /// group and the committed rows written above it are both live: the
    /// erase has to climb past the gap to reach the retirement, so
    /// dropping the gap would move the row it aims at. Only the PRODUCT
    /// commits history — appending a line does not commit the popup rows
    /// or the retired transcript above them — so a session whose popup
    /// left a retirement behind keeps it across any number of later
    /// transcript lines, and the boundary is the first retired entry and
    /// never the last. With no retired entry at all nothing is owed and
    /// the whole ledger goes.
    fn firstRetired(self: *const Region) usize {
        for (self.owned.items, 0..) |g, i| {
            if (g.kind == .retired) return i;
        }
        return self.owned.items.len;
    }

    /// Whether two adjacent ledger groups are one run. Adjacent blanks
    /// always are, and so are same-kind groups when no model is declared,
    /// because then a group is a distance and nothing else: it carries no
    /// geometry, and nothing may erase, trim or repack it, so one entry
    /// per row would be the ledger growing without bound for a length it
    /// could have said once. Under a declared model every committed row
    /// is its own hard group with its own width-2 positions and unprinted
    /// intervals, and folding two together would destroy exactly what the
    /// next repack reads.
    fn mergesWith(self: *const Region, a: Owned, b: Owned) bool {
        if (a.kind != b.kind) return false;
        return a.kind == .blank or !self.nativeReflow();
    }

    /// Reclaim what the ledger no longer needs.
    ///
    /// Two things accumulate otherwise. Adjacent blank runs pile up: a
    /// band that grows and shrinks on every tick of a REPL leaves one
    /// entry per transition, all of them hard blanks the projection only
    /// counts. And the tapes the widths and unprinted intervals live on
    /// are append-only, so every group taken out of the ledger leaves
    /// its entries behind — which matters twice over, because they are
    /// the largest thing a long native session holds and because every
    /// record indexes its slice by offset, so a reclaimed span has to
    /// be moved and rebased rather than merely dropped.
    ///
    /// It runs on the frames that CHANGED the ledger, never on every
    /// commit. A steady session appends nothing, removes nothing and
    /// rebases nothing; walking a ledger that has not changed since the
    /// last walk, once per frame, is pure cost on the frame that is
    /// supposed to cost nothing.
    ///
    /// The tapes are rebuilt in LEDGER ORDER, which is the only order
    /// that leaves nothing dead: a group taken out of the middle, and a
    /// survivor rebased onto the tail, both leave a hole that dropping a
    /// prefix cannot reach, and a hole is metadata a session pays for
    /// on every later frame. One pass leaves the tapes dense, so the
    /// next change pays for one pass and not for every pass since the
    /// first.
    ///
    /// The move is forward and in place, never through a second buffer:
    /// for two ledger groups `i < j` the destination of everything up
    /// to `i` never reaches the source of `j`, because every live span
    /// of a group before `j` was appended no later than `j`'s own, and
    /// a rebased survivor is never longer than the span it replaced.
    /// That is what lets the pass be infallible, which matters because
    /// it runs from `commit` where a second allocating pass is not
    /// allowed to exist.
    fn compactLedger(self: *Region) void {
        if (!self.ledger_dirty) return;
        self.ledger_dirty = false;
        // Drop only the prefix before the earliest retirement obligation.
        // Offsets are counted from the tail, so this moves no target.
        // Keep the committed rows and blank gaps after that obligation:
        // erase has to climb past them to reach the retirement and only
        // the product commits history.
        //
        // The band's own geometry is not here — that is `band_fp`, kept
        // whole whatever this ledger does.
        const live = self.firstRetired();
        if (live > 0) self.owned.replaceRangeAssumeCapacity(0, live, &.{});
        var keep: usize = 0;
        for (self.owned.items) |g| {
            if (keep > 0 and self.mergesWith(self.owned.items[keep - 1], g)) {
                self.owned.items[keep - 1].rows += g.rows;
                continue;
            }
            self.owned.items[keep] = g;
            keep += 1;
        }
        if (keep < self.owned.items.len) self.owned.shrinkRetainingCapacity(keep);
        if (!self.nativeReflow()) return; // nothing was ever recorded on a tape
        // The tapes are in the order the BYTES went out and the ledger in
        // the order the groups appear on screen, and the repack below
        // reads them as one. That is exact because a frame can never
        // have both tails non-empty: `ledger_out` belongs to
        // `paintCollapse`, `paintResize` and `paintPhysical`, none of
        // which writes above the band, and the staged rows above it come
        // from `writeAppends` and `writeHistoryBatches`, which only
        // `paintFirst` and `paintLedger` call — and `planStrategy` hands
        // each painter at most one of the two. `commit` asserts it; a
        // future painter that broke it would make this read a span past
        // an unread one, silently.
        var wide_at: usize = 0;
        var null_at: usize = 0;
        for (self.owned.items) |*g| {
            if (g.kind == .blank) continue;
            @memmove(
                self.wide_tape.items[wide_at..][0..g.fp.wide_count],
                self.wide_tape.items[g.fp.wide_start..][0..g.fp.wide_count],
            );
            g.fp.wide_start = wide_at;
            wide_at += g.fp.wide_count;
            @memmove(
                self.null_tape.items[null_at..][0..g.fp.null_count],
                self.null_tape.items[g.fp.null_start..][0..g.fp.null_count],
            );
            g.fp.null_start = null_at;
            null_at += g.fp.null_count;
        }
        self.wide_tape.shrinkRetainingCapacity(wide_at);
        self.null_tape.shrinkRetainingCapacity(null_at);
    }

    // ── commit ────────────────────────────────

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
        if (f.clear_height_dirty) self.height_dirty = false;
        if (f.clear_physical) self.physical_dirty = false;
        if (f.release) self.released = true;
        if (f.hide_cursor) self.cursor_hidden = true;
        if (f.show_cursor) self.cursor_hidden = false;
        // A replay supersedes the append queue, so it is dropped with
        // the batches it replaces — both on the wire and in the
        // retained state.
        if (f.took_appends) self.append_queue.clearRetainingCapacity();
        // Settle visible retirements FIRST, from the pre-frame ledger,
        // extent and measured reach both cleanup paths used. Recomputing
        // after the band moved would settle rows the frame never reached.
        self.retireLedger();
        // The reclaimed contiguous suffix is not a gap: the new band
        // top moved over it. Remove it only at commit, after the same
        // pre-frame reach has settled every other retirement.
        var reclaimed = f.reclaimed;
        while (reclaimed > 0) {
            const i = self.owned.items.len - 1;
            const rows = self.groupRows(self.owned.items[i]);
            std.debug.assert(self.owned.items[i].kind == .blank);
            if (rows <= reclaimed) {
                self.owned.items.len = i;
                reclaimed -= rows;
            } else {
                self.owned.items[i].rows = rows - reclaimed;
                reclaimed = 0;
            }
            self.ledger_dirty = true;
        }
        // The rows the band gives up join the ledger next, in band-row
        // order, which is their order on screen: band row 0 is the
        // topmost, so it is the earliest entry and the row nearest the
        // band top is the last.
        if (f.ledger_out) |out| self.handOver(out);
        // Then everything this frame wrote above the band, staged with
        // the geometry the terminal was handed, and the blank rows a
        // reservation created between it and them.
        for (self.pending_owned.items) |g| self.owned.appendAssumeCapacity(g);
        if (f.band_push > 0) {
            self.owned.appendAssumeCapacity(.{ .kind = .blank, .rows = f.band_push });
            // A blank run can land next to another — two reservations in
            // a row, or a released tail against the gap before it — and
            // only the reclaim pass folds them into one entry.
            self.ledger_dirty = true;
        }
        if (f.ledger_out != null or self.pending_owned.items.len > 0) {
            // A hand-over changes what the ledger owes; a flush BURIES
            // whatever retired run was there, which is the other half of
            // what the reclaim pass is for.
            self.ledger_dirty = true;
        }
        // The band's own geometry is published only now, after the rows
        // that left it have been copied into the ledger — and only when
        // this frame actually recaptured it, so a frame that changed no
        // cell keeps the committed footprints standing.
        if (self.pending_band.items.len == self.cur.height) {
            self.band_fp.clearRetainingCapacity();
            self.band_fp.appendSliceAssumeCapacity(self.pending_band.items);
            std.mem.swap(std.ArrayList(u16), &self.band_tape, &self.band_next);
            std.mem.swap(
                std.ArrayList(Buffer.RowFootprint.NullGap),
                &self.band_gaps,
                &self.band_next_gaps,
            );
        }
        // Whatever this frame took out of the ledger releases what it was
        // holding, so a session that writes, clips and trims for hours
        // does not grow without bound.
        // The tapes are appended in the order the BYTES go out and the
        // ledger in the order the groups appear on screen; the reclaim
        // pass reads them as one, and that is exact only while a frame
        // never has both tails non-empty. Asserted rather than handled:
        // the painter call graph proves it (see `compactLedger`), and a
        // frame that broke it would corrupt the repack silently.
        std.debug.assert(f.ledger_out == null or self.pending_owned.items.len == 0);
        // The physical extent is bookkeeping for cursor moves only. The
        // absolute anchor is never accumulated: it is derived from the
        // cursor row every frame walked, so a frame that pushed the band
        // onto the window's last row — where the cursor moved and the
        // band's top did not — still reports the row the terminal put it
        // on.
        self.painted_rows = f.painted;
        self.last_width = self.width;
        self.high_water = f.high_water;
        if (f.ledger_out != null or self.pending_owned.items.len > 0 or
            f.band_push > 0 or self.pending_band.items.len == self.cur.height)
        {
            self.trimToCapacity();
        }
        self.compactLedger();
        // Every painter ends parked on the band bottom, so the cursor is
        // exactly the band's own projected extent below the band top; a
        // release parks it on the settled row it had, which is now the
        // top itself.
        self.cursor_off = if (f.painted > 0) @as(i32, @intCast(self.bandRows() -| 1)) else 0;
        // The cursor's row on the screen, as the frame walked it: one
        // step per emitted move, in order, each clamped at the edge of
        // the viewport it is in — a CUU stops at the window's first row
        // and a newline on its last scrolls and stays. An app that has
        // reported no winsize gets no credit at all, the safe reading.
        self.cursor_screen = @intCast(@max(0, f.cursor));
        // A reply still waiting is extended by this frame's walk through
        // the same viewport boundary a real cursor met — not by the net
        // distance it travelled, which loses every clamp on the way.
        if (self.query_outstanding) {
            self.query_shift = f.query_shift;
            self.query_low = f.query_low;
            self.query_high = f.query_high;
        }
        // The band is released exactly when it occupies no rows and the
        // app asked for no band: derived here, after the extent this
        // frame settled, never latched by whichever call noticed.
        self.collapsed = self.height == 0 and self.painted_rows == 0;
        if (f.anchor_dirty) self.anchor_dirty = true;
        if (f.query) self.takeQuery();
        if (f.replay) |at| self.applyReplay(at);
        if (f.took_history) self.history_written = self.history.items.len;
        // Infallible: `render` prepared the snapshot before a single
        // byte was staged, so this only publishes it.
        self.publishSnapshot();
    }

    /// Publish a query only after its complete bytes have been staged.
    /// The same single slot serves prepaint and postpaint measurements.
    fn takeQuery(self: *Region) void {
        self.anchor_dirty = false;
        self.query_outstanding = true;
        self.query_stale = false;
        self.query_gen = self.geom_gen;
        self.query_shift = 0;
        self.query_low = 0;
        self.query_high = if (self.term_rows == 0)
            std.math.maxInt(i32)
        else
            @as(i32, self.term_rows) - 1;
    }

    /// Move the band rows this frame released into the ownership ledger.
    ///
    /// They are read off `band_fp` before the band's geometry is
    /// republished, so a row keeps exactly the footprint it was painted
    /// with — and a retired one keeps it after its text is gone, which is
    /// the whole point of keeping geometry rather than content.
    ///
    /// The rows leaving the band are always its TOPMOST ones — a
    /// re-base, a rebuild and a collapse all leave the bottom — so they
    /// are band rows `0..rows`, and band row 0 is the furthest from the
    /// new band top. They are appended in that order, which is
    /// earliest-first for the ledger.
    ///
    /// A native band row can be several physical rows tall, and a clip
    /// boundary can fall inside one. That row is split at the exact chunk
    /// the producer reports: unreachable chunks above the cut remain
    /// retired. A physical re-base supplies its exact erased extent
    /// separately, because that blank gap can cross further logical rows;
    /// the surviving chunks of this one boundary row are not the whole
    /// gap. Other hand-overs retain their per-logical-row settlement.
    ///
    /// A `.rebuild` is the one hand-over whose LAST row is cut from the
    /// other end: it repaints starting on the cursor's own row, so every
    /// chunk of that row above the cursor is settled history and the
    /// cursor's own chunk is not settled at all. `settled_chunks` carries
    /// that cut, so a multi-row band row still hands over the exact groups
    /// the terminal had.
    fn handOver(self: *Region, out: LedgerOut) void {
        const rows: usize = @intCast(@min(out.rows, self.painted_rows));
        const retired_upto = @min(out.retired_rows, @as(u32, @intCast(rows)));
        for (0..rows) |i| {
            if (self.bandRowRows(@intCast(i)) == 0) continue;
            if (i < retired_upto) {
                self.appendBandGroup(i, .retired, null);
                continue;
            }
            if (i == retired_upto and out.retired_chunks > 0 and i < rows) {
                const total = self.bandRowRows(@intCast(i));
                const cut = total -| out.retired_chunks;
                self.appendBandGroup(i, .retired, out.retired_chunks);
                if (cut > 0 and out.erased_rows == null) {
                    self.owned.appendAssumeCapacity(.{ .kind = .blank, .rows = cut });
                }
                continue;
            }
            if (out.settled == .blank) {
                self.owned.appendAssumeCapacity(.{
                    .kind = .blank,
                    .rows = self.bandRowRows(@intCast(i)),
                });
                continue;
            }
            // A `.rebuild` paints over the cursor's OWN row, so the last
            // row leaving the band keeps only the chunks above it — and
            // a one-row last row keeps none of them at all.
            if (i + 1 == rows) {
                if (out.settled_chunks) |keep| {
                    if (keep == 0) continue;
                    self.appendBandGroup(i, .committed, keep);
                    continue;
                }
            }
            self.appendBandGroup(i, .committed, null);
        }
        if (out.erased_rows) |erased| {
            if (erased > 0) {
                self.owned.appendAssumeCapacity(.{ .kind = .blank, .rows = erased });
            }
        }
    }

    /// Copy band row `y`'s committed footprint into the ledger tapes and
    /// append it. `keep` limits it to that many of the row's PHYSICAL
    /// chunks — the top ones when `keep` is given — so a boundary that
    /// falls inside a multi-row band row still yields a group the
    /// terminal actually had, at the exact chunk cut.
    fn appendBandGroup(self: *Region, y: usize, kind: @FieldType(Owned, "kind"), keep: ?u32) void {
        if (y >= self.band_fp.items.len) {
            self.owned.appendAssumeCapacity(.{ .kind = kind, .rows = 1 });
            return;
        }
        var src = self.band_fp.items[y].fp;
        var rows = self.bandRowRows(@intCast(y));
        if (rows == 0) return;
        if (keep) |k| {
            src = src.prefixRows(self.band_tape.items, self.width, k);
            src.columns = flatten(
                src,
                self.band_tape.items,
                self.band_gaps.items,
                self.width,
                k,
            );
            rows = k;
        }
        const wide_start = self.wide_tape.items.len;
        for (self.band_tape.items[src.wide_start..][0..src.wide_count]) |col| {
            if (col >= src.columns) break;
            self.wide_tape.appendAssumeCapacity(col);
        }
        const null_start = self.null_tape.items.len;
        for (self.band_gaps.items[src.null_start..][0..src.null_count]) |gap| {
            if (gap.start >= src.columns) break;
            self.null_tape.appendAssumeCapacity(.{
                .start = gap.start,
                .end = @min(gap.end, src.columns),
            });
        }
        const fp: Buffer.RowFootprint = .{
            .columns = src.columns,
            .wide_start = wide_start,
            .wide_count = self.wide_tape.items.len - wide_start,
            .null_start = null_start,
            .null_count = self.null_tape.items.len - null_start,
        };
        self.owned.appendAssumeCapacity(.{ .fp = fp, .kind = kind, .rows = @max(rows, 1) });
    }

    /// Stage the committed snapshot's next grid, then copy the current
    /// frame's cell text into the scratch arena and record the per-cell
    /// owned slices. The only fallible steps of a frame, and they run
    /// BEFORE any byte is staged: on `error.OutOfMemory` the live
    /// snapshot, `prev`, the dirty flags and the byte stream are all
    /// exactly as they were — no half-written frame, no split state, no
    /// silent repaint-everything fallback.
    ///
    /// The shape is STAGED into `prev_next` and published only by the
    /// commit. The external resize is what moved `cur`, and a frame that
    /// dies staging its bytes has to leave the committed snapshot whole —
    /// so the shape follows the composition that will publish into it,
    /// not the resize that made one necessary. A session whose grid has
    /// not moved never reaches the stage, and pays two comparisons.
    ///
    /// The scratch arena is reset with its capacity retained and the
    /// slice list is reused, so once a session has reached its
    /// high-water mark this allocates nothing per frame.
    fn prepareSnapshot(self: *Region) error{OutOfMemory}!void {
        // A stage a failed frame left behind is reused only while the
        // external geometry has not moved AGAIN since: the publish copies
        // one grid into the other, so a candidate on the wrong grid is
        // worse than none — it would be swapped in over a `cur` of a
        // different length. The committed `prev` is untouched on either
        // path, including the allocation that fails after a stale
        // candidate was released.
        if (self.prev_next) |staged| {
            if (staged.width != self.cur.width or staged.height != self.cur.height) {
                self.gpa.free(staged.cells);
                self.prev_next = null;
            }
        }
        if (self.prev_next == null and
            (self.prev.width != self.cur.width or self.prev.height != self.cur.height))
        {
            const next = try Buffer.init(self.gpa, self.cur.width, self.cur.height);
            const overlap_h: usize = @min(self.prev.height, self.cur.height);
            const overlap_w: usize = @min(self.prev.width, self.cur.width);
            for (0..overlap_h) |y| {
                @memcpy(
                    next.cells[y * self.cur.width ..][0..overlap_w],
                    self.prev.cells[y * self.prev.width ..][0..overlap_w],
                );
            }
            self.prev_next = next;
        }
        self.snapshot_cells.clearRetainingCapacity();
        _ = self.snapshot_scratch.reset(.retain_capacity);
        const arena = self.snapshot_scratch.allocator();
        try self.snapshot_cells.ensureTotalCapacity(self.gpa, self.cur.cells.len);
        for (self.cur.cells) |cell| {
            // Static graphemes (every cell `Buffer.draw` wrote from ASCII,
            // and the default blank) are immutable, so `prev` owns them as
            // they are; a borrowed one-byte ASCII slice maps onto the same
            // table. Only the rest is copied, so a mostly-ASCII frame pays
            // almost no per-cell allocation.
            if (cell.grapheme.len == 0 or Cell.isStaticGrapheme(cell.grapheme)) continue;
            const owned = if (cell.grapheme.len == 1 and cell.grapheme[0] < 0x80)
                Cell.asciiGrapheme(cell.grapheme[0])
            else
                try arena.dupe(u8, cell.grapheme);
            self.snapshot_cells.appendAssumeCapacity(owned);
        }
    }

    /// Publish the prepared snapshot: the staged grid becomes `prev` if
    /// the external geometry moved it, `prev` takes `cur`'s cells with
    /// their text owned by the Region, and the arenas swap so the next
    /// prepare builds in the retired one. Infallible by construction —
    /// and the shape it publishes is one this commit's own composition
    /// prepared, never one an aborted frame left behind.
    fn publishSnapshot(self: *Region) void {
        if (self.prev_next) |next| {
            self.gpa.free(self.prev.cells);
            self.prev = next;
            self.prev_next = null;
        }
        @memcpy(self.prev.cells, self.cur.cells);
        // Cells with no text keep `cur`'s (empty) slice, which has
        // nothing to own, and static graphemes need no copy; every other
        // cell takes its prepared one. The skip mirrors `prepareSnapshot`.
        var next: usize = 0;
        for (self.prev.cells) |*cell| {
            if (cell.grapheme.len == 0 or Cell.isStaticGrapheme(cell.grapheme)) continue;
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
    fn moveToBandTop(self: *const Region, w: anytype, f: *Frame, painted: anytype) !void {
        _ = self;
        try w.writeAll("\r");
        if (painted > 1) {
            try w.print("\x1b[{d}A", .{painted - 1});
            f.up(painted - 1);
        }
    }

    // ── diff bookkeeping ─────────────────────────────

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
    /// never read bytes the app has since rewritten in place. Shares
    /// `Buffer.rowChanged`'s whole-row byte compare before the per-cell one.
    fn rowEqual(self: *const Region, y: usize) bool {
        return !self.cur.rowChanged(&self.prev, y);
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

    // ── row emission ──────────────────────────────

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

// ── envelope fragments ─────────────────────────────
const sync_on = "\x1b[?2026h";
const sync_off = "\x1b[?2026l";
const hide_c = "\x1b[?25l";
const show_c = "\x1b[?25h";
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
    /// The declared native model, with the scrollback retention it is
    /// only meaningful together with. `.none` is the default and is
    /// what every non-native test runs under.
    terminal_reflow: Region.TerminalReflow = .none,
};

fn makeRegion(h: u16, m: RegionMode) !Region {
    return Region.init(testing.allocator, .{
        .height = h,
        .interactive = m.interactive,
        .sync_output = m.sync,
        .append_lines = m.append_lines,
        .resize_mode = m.mode,
        .max_history_bytes = m.max_history,
        .terminal_reflow = m.terminal_reflow,
    });
}

/// A Region under the declared native model, with the exact scrollback
/// retention a caller configuring that terminal has to state.
fn makeNativeRegion(h: u16, mode: RegionMode, scrollback: u32) !Region {
    var native = mode;
    native.terminal_reflow = .{ .non_cursor_rows = .{ .scrollback_rows = scrollback } };
    return makeRegion(h, native);
}

fn drawRow(buf: *Buffer, y: u16, text: []const u8) !void {
    _ = try buf.draw(Style{}, text, 0, y);
}

/// The same text in every band row: the content most erase, diff and
/// reflow tests drive, and it keeps the expected bytes readable.
fn fillBand(buf: *Buffer, text: []const u8) !void {
    for (0..buf.height) |y| try drawRow(buf, @intCast(y), text);
}

/// Band-row labels `[row][set]`, built once as STATIC storage: a
/// `Buffer` cell BORROWS the bytes it is given (the Region copies them
/// only at commit), so label bytes handed to `draw` must outlive the
/// frame that paints them. A function-local array would dangle by then.
const labels = blk: {
    var table: [10][2][2]u8 = undefined;
    for (0..10) |y| {
        table[y][0] = .{ 'a', '0' + @as(u8, @intCast(y)) };
        table[y][1] = .{ 'b', '0' + @as(u8, @intCast(y)) };
    }
    break :blk table;
};

/// The band row `row` painted with `tag`: two characters, so a terminal
/// assertion can name the exact band row a byte landed on, and a
/// redraw under another tag is damage on every row.
fn label(tag: u8, row: usize) []const u8 {
    const set: usize = if (tag == 'a') 0 else 1;
    return labels[row][set][0..];
}

/// Paint a distinct label into each of `rows` band rows.
fn tagRows(buf: *Buffer, rows: u16, tag: u8) !void {
    for (0..@as(usize, rows)) |y| {
        try drawRow(buf, @intCast(y), label(tag, y));
    }
}

/// The settled transcript above the band: five rows no frame may touch,
/// so a cursor that leaves the band is visible instead of hidden above
/// row 0 where a relative walk clamps.
const history_rows = [_][]const u8{ "hist0", "hist1", "hist2", "hist3", "hist4" };

/// Park the terminal model on the first row BELOW `history_rows` — the
/// row the band's top will occupy when it is painted in place.
fn feedHistory(term: *Term) void {
    for (history_rows) |row| {
        term.feed(row);
        term.feed("\r\n");
    }
}

/// Band row `row` under tag `tag` sits on terminal row `at`.
fn expectLabel(term: *const Term, at: usize, tag: u8, row: usize) !void {
    try testing.expectEqualStrings(label(tag, row), term.text(at));
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
    return sync_on ++ aw_on ++ body ++ sync_off;
}

/// A terminal model for the frames the Region emits: it interprets the
/// C0 and CSI subset of the byte stream — CR, LF, CUU/CUD/CUF/CUB,
/// CNL/CPL, CHA, CUP, ED0, EL — and records where every printable
/// byte lands. SGR, DEC private modes and the CPR query are ignored:
/// they move no cursor and paint no cell.
///
/// Cursor MOVES never hand out a new row: CUU, CUD and CNL stop at the
/// last visible row, so a band parked there cannot be grown by one. LF
/// on that row does scroll the viewport — the one motion a terminal
/// answers with rows, and what the reservation uses.
///
/// `visible`/`top` model a physical terminal HEIGHT: `grid` is the
/// scrollback, `top` is the first row ON SCREEN, and every cursor move
/// clamps inside that viewport — the boundary a real terminal stops at
/// when its window is dragged shorter than the content already on it.
const Term = struct {
    const rows = 24;
    const cols = 80;
    /// Buffer rows the model holds: the screen plus the scrollback a
    /// frame may push into it. A scroll keeps the row it displaced, so
    /// committed history that leaves the screen is still nameable.
    const cap = rows * 2;
    const blank: [cols]u8 = [_]u8{' '} ** cols;

    grid: [cap][cols]u8 = [_][cols]u8{blank} ** cap,

    /// Rows the screen shows, `rows` until `resizeRows` says otherwise.
    visible: usize = rows,
    /// Grid row the screen starts at — what `screenText(0)` shows. A
    /// physical resize pushes the rows above it into scrollback: they
    /// stay in `grid`, and no cursor move can reach them again.
    ///
    /// A scroll moves it down a row for the same reason: the row it
    /// passed is scrollback now, still in `grid`, reachable by nothing.
    ///
    /// A window that grows taller moves it back up over the scrollback
    /// the window can show, and what that scrollback cannot cover is
    /// added BELOW the cursor's line as blank rows: the rows a band gave
    /// up are on the screen again, above the band.
    top: usize = 0,

    row: usize = 0,
    col: usize = 0,

    /// The `CSI 6 n` queries the frames emitted and the 1-indexed
    /// `(row, column)` the model would answer each with, oldest first.
    ///
    /// A real terminal answers immediately, from the cursor it has at
    /// the moment the query arrives, and the app routes that reply
    /// through `applyCpr`. Recording it here is what lets a test do the
    /// same instead of inventing a reply for a query nothing asked —
    /// which is the only way the Region's measured reach, its retirement
    /// erase and its absolute anchor can be exercised at all.
    queries: [16][2]u16 = undefined,
    query_count: usize = 0,

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
                // CR itself, so this stays exact. On the last visible
                // row it SCROLLS instead of stopping, as a terminal
                // does — a cursor move clamps there, LF does not.
                '\n' => {
                    if (self.row < self.bottom()) {
                        self.row += 1;
                    } else {
                        self.scroll();
                    }
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
            // Every vertical move clamps to the VIEWPORT, never the
            // grid: rows above the screen top are scrollback, and a
            // real terminal stops there instead of reaching into it.
            'A' => self.row = @max(r -| a, self.top), // CUU
            'B' => self.row = @min(r + a, self.bottom()), // CUD
            'C' => self.col = @min(c + a, cols - 1), // CUF
            'D' => self.col = if (c > a) c - a else 0, // CUB
            'E' => { // CNL
                self.row = @min(r + a, self.bottom());
                self.col = 0;
            },
            'F' => { // CPL
                self.row = @max(r -| a, self.top);
                self.col = 0;
            },
            'G' => self.col = @min(a -| 1, cols - 1), // CHA
            'H', 'f' => { // CUP
                self.row = @min(self.top + (@as(usize, params[0]) -| 1), self.bottom());
                self.col = @min(@as(usize, params[1]) -| 1, cols - 1);
            },
            'J' => switch (params[0]) { // ED — the screen only, never scrollback
                0 => self.eraseBelow(r, c),
                2 => @memset(self.grid[self.top .. self.bottom() + 1], blank),
                else => {},
            },
            'K' => switch (params[0]) { // EL
                0 => self.eraseLineFrom(r, c),
                1 => self.eraseLineTo(r, c),
                else => {},
            },
            // DSR: the query is a REPORT REQUEST, so it moves nothing —
            // but the answer it owes is the one measurement the whole
            // anchor protocol rests on, so it is recorded rather than
            // dropped.
            'n' => if (params[0] == 6) {
                std.debug.assert(self.query_count < self.queries.len);
                self.queries[self.query_count] = .{
                    @intCast(r - self.top + 1),
                    @intCast(c + 1),
                };
                self.query_count += 1;
            },
            'h', 'l', 'm', 'r' => {}, // modes, SGR: no geometry
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
        for (self.grid[r + 1 .. self.bottom() + 1]) |*line| @memset(line, ' ');
    }

    /// Row `r` as text, trailing blanks removed.
    fn text(self: *const Term, r: usize) []const u8 {
        var line: []const u8 = &self.grid[r];
        while (line.len > 0 and line[line.len - 1] == ' ') line = line[0 .. line.len - 1];
        return line;
    }

    /// Last grid row ON SCREEN.
    fn bottom(self: *const Term) usize {
        return self.top + self.visible - 1;
    }

    /// LF on the last visible row: the viewport scrolls up one row and
    /// the row it vacated is blank below. The row that left the top
    /// stays in `grid` above `top` — scrollback, which no cursor move
    /// reaches and nothing may rewrite.
    fn scroll(self: *Term) void {
        std.debug.assert(self.bottom() + 1 < cap);
        self.top += 1;
        self.row = self.bottom();
        self.grid[self.row] = blank;
    }

    /// A physical resize to `visible` rows, as a winsize does.
    ///
    /// SHORTER: the cursor keeps its line. The rows above it that no
    /// longer fit scroll into scrollback (the grid keeps those rows and
    /// `top` moves down past them); the rows the window gives up are the
    /// tail BELOW the cursor. So a cursor that still fits keeps the row
    /// it is on — and a cursor that does not lands on the new last row,
    /// because a terminal keeps it visible rather than handing scrollback
    /// back to make room for it.
    ///
    /// TALLER: the window is handed back the scrollback it still holds —
    /// the rows above `top` are on the screen again — and whatever the
    /// scrollback cannot cover is ADDED BELOW the cursor's line as blank
    /// rows. A terminal that has run out of scrollback grows that way: the
    /// cursor's line keeps its place and the new rows are empty, so a
    /// window restored under a band that sits high on the screen shows
    /// blank rows below it (the 97x28 capture: the live band at rows 8..13
    /// of 28) rather than pushing the cursor's row to the new bottom.
    ///
    /// The pull happens only while the cursor sits on the LAST line the
    /// terminal holds. A logically dismissed band parks the cursor
    /// upward with blank rows under it — a `setHeight` shrink erases the
    /// tail it released and stays on the same rows — and the window then
    /// grows DOWNWARD instead: xterm's observed `Buffer.resize` appends
    /// blank lines below the cursor and leaves `ybase`/`ydisp` alone, so
    /// `top` does not move and nothing above the cursor's line becomes
    /// visible. That is what keeps a dismissed popup's retired rows out
    /// of reach until a pull really happens.
    ///
    /// `grid` is the terminal's whole buffer, screen and scrollback, so a
    /// growth that would run past it is refused the way a bounded
    /// scrollback is — the rows it cannot add are simply not there.
    fn resizeRows(self: *Term, visible: usize) void {
        const want = @min(@max(visible, 1), rows);
        if (want <= self.visible) {
            const screen_row = self.row - self.top;
            self.visible = want;
            self.top += screen_row -| (want - 1);
            return;
        }
        const old_bottom = self.bottom();
        const gained = want - self.visible;
        // Scrollback reaches the screen only while the cursor is on the
        // window's last row; a blank tail below it means the new rows
        // are appended under the cursor instead.
        const handed_back = if (self.row == old_bottom) @min(gained, self.top) else 0;
        const added = @min(gained - handed_back, cap - 1 -| old_bottom); // blank rows below
        self.top -= handed_back;
        self.visible += handed_back + added;
        // The rows the window gained below are new: nothing ever wrote
        // them, and a terminal hands back an empty row.
        for (old_bottom + 1..self.bottom() + 1) |r| self.grid[r] = blank;
    }

    /// Row `y` as the SCREEN shows it: screen row 0 is `top`.
    fn screenText(self: *const Term, y: usize) []const u8 {
        return self.text(self.top + y);
    }

    /// The cursor's row as the screen shows it, from the top visible row.
    fn screenRow(self: *const Term) usize {
        return self.row - self.top;
    }
};

/// The committed transcript a full screen holds above a band that sits
/// on its last rows: row `y` reads `t<yy>` in STATIC storage (the
/// borrowed bytes must outlive the frame), and no two rows read the
/// same — a row the screen scrolls off the top still has to be
/// nameable, and a row a band painted over must be detectable as
/// missing.
const transcript = blk: {
    var table: [Term.rows - 2][3]u8 = undefined;
    for (0..table.len) |y| {
        table[y][0] = 't';
        table[y][1] = '0' + @as(u8, @intCast(@divTrunc(y, 10)));
        table[y][2] = '0' + @as(u8, @intCast(y % 10));
    }
    break :blk table;
};

/// Committed transcript row `y`.
fn transcriptRow(y: usize) []const u8 {
    return transcript[y][0..];
}

/// Park the model on row `at` with the transcript written above it, so
/// the band's first frame paints in place from there. `at` rows are on
/// screen: the ones above the band are committed history no frame may
/// rewrite.
fn feedTranscript(term: *Term, at: usize) void {
    std.debug.assert(at <= transcript.len);
    for (0..at) |y| {
        term.feed(transcriptRow(y));
        term.feed("\r\n");
    }
}

/// Buffer rows holding exactly `needle`: a committed row that scrolled
/// off the top is still in the buffer, one a band painted over is
/// gone — and one a frame duplicated shows up here twice.
fn rowsHolding(term: *const Term, needle: []const u8) usize {
    var held: usize = 0;
    for (0..Term.cap) |r| {
        if (std.mem.eql(u8, term.text(r), needle)) held += 1;
    }
    return held;
}

/// Every committed transcript row is still in the terminal's buffer,
/// exactly once: the rows a frame's scroll pushed off the screen are
/// scrollback, the rows a band painted over are GONE, and a row nothing
/// lost is never duplicated.
fn expectTranscriptIntact(term: *const Term) !void {
    for (0..transcript.len) |y| {
        try testing.expectEqual(@as(usize, 1), rowsHolding(term, transcriptRow(y)));
    }
}

/// Route the replies the model owes the Region, oldest first, and clear
/// the queue: every `CSI 6 n` a frame actually emitted, answered with the
/// cursor the model really had when it arrived.
///
/// That is the whole query protocol a session follows, and it is the only
/// way a test reaches a MEASURED state — the absolute anchor, the reach a
/// retirement erase is bounded by, the "a reply under the live geometry"
/// rule — without inventing a report for a query nothing sent. The
/// reach is unknown until a real reply lands, and every erase waits for
/// it, so a test that skips this answers nothing the Region may act on.
///
/// Extra renders that the answer unlocks are the point, not padding: a
/// frame whose reach was unknown emits no erase, and the frame after the
/// reply is the one that takes the rows back.
fn answerQuery(r: *Region, term: *Term) !void {
    const owed = term.queries[0..term.query_count];
    term.query_count = 0;
    for (owed) |reply| try r.applyCpr(reply[0], reply[1]);
}

/// The REPL popup a typing prompt paints, top to bottom: the live input
/// row, the candidates under it (the selected one carries the `>`
/// gutter), the status row. A popup `rows` rows tall is its first
/// `rows` rows, so the same string identifies a popup row in every
/// version of the popup — which is what makes a restored row nameable.
const popup_rows = [_][]const u8{
    "skript> d", // the live input row
    "> deg->rad", // the selected candidate, under it
    "  defn", // the rest of the candidates
    "  degree",
    "  deriv",
    "status", // the status row
};

/// Paint the first `rows` rows of the popup into the band buffer.
fn drawPopup(buf: *Buffer, rows: u16) !void {
    for (0..@as(usize, rows)) |y| try drawRow(buf, @intCast(y), popup_rows[y]);
}

/// Screen rows above `band_top` that still hold one of `rows`: a row
/// this session's band painted and gave up, handed back to the screen by
/// a viewport growth. Nothing committed that text and no frame has
/// claimed it since, so it is residue the user reads above the live
/// band. The rows are distinct, so a screen row counts at most once.
fn restoredBandRows(term: *const Term, band_top: usize, rows: []const []const u8) usize {
    var held: usize = 0;
    for (0..band_top) |y| {
        const text = term.screenText(y);
        for (rows) |row| {
            if (std.mem.eql(u8, text, row)) held += 1;
        }
    }
    return held;
}

// ── options ─────────────────────────────────

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

test "region: the first frame is wrapped once: sync, hide, autowrap on, body, end" {
    var r = try makeRegion(2, .{ .append_lines = true });
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    const frame = t.bytes();
    // Sync brackets the body once. Autowrap is enabled before any row
    // write and stays on; a full-width row's final CR clears deferred wrap.
    try testing.expect(std.mem.startsWith(u8, frame, sync_on ++ hide_c ++ aw_on));
    try testing.expect(std.mem.endsWith(u8, frame, sync_off));
    for ([_][]const u8{ sync_on, sync_off, hide_c, aw_on }) |fragment| {
        try testing.expectEqual(@as(usize, 1), count(frame, fragment));
    }
    // The band owns the two rows reserved below the cursor, one terminal
    // row each, starting directly below the cursor's own row, and the
    // cursor parks on the last one.
    var term: Term = .{};
    term.feed(frame);
    try testing.expectEqualStrings("", term.text(0));
    try testing.expectEqualStrings("ab", term.text(1));
    try testing.expectEqualStrings("cd", term.text(2));
    try testing.expectEqual(@as(usize, 2), term.row);
    try testing.expectEqual(@as(usize, 0), term.col);
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
    try testing.expectEqualStrings(hide_c ++ aw_on ++ "\rhi\r" ++ cpr_q, t.bytes());
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
    try testing.expectEqualStrings(aw_on ++ "\r\r\x1b[Kyo\r", t2.bytes());
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
        sync_on ++ aw_on ++ "\r\r\x1b[Kb\r" ++ sync_off ++ show_c,
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
    // inside the sync bracket, ahead of autowrap-on.
    try testing.expectEqualStrings(
        sync_on ++ hide_c ++ aw_on ++ "\r\r\x1b[Kc\r" ++ sync_off,
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
    var term: Term = .{};
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());
    try testing.expectEqual(@as(usize, 0), count(t1.bytes(), "\x1b[J"));
    // The first frame's query is answered, so the slot is free and the
    // re-anchor the redraw owes can actually go out on the frame after it.
    try answerQuery(&r, &term);

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
    try testing.expectEqualStrings(framed("\r" ++ cpr_q), t3.bytes());
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
    try r.resize(4, Term.rows, 2);
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
    try r.resize(4, Term.rows, 1);
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
    try r.resize(4, Term.rows, 2);
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
    try testing.expectEqual(@as(usize, 0), (try r.historyPending()).len);
    try testing.expectEqual(@as(usize, 0), r.historyBytes());
}

test "region: a piped session writes its plain frame once, whatever the height does" {
    // A pipe has no band and no cursor: `renderPlain` publishes the one
    // frame it gets and nothing else, so `painted_rows` stays 0 for the
    // whole session. A later height change must not read that zero as
    // "the band was released" — the second plain frame would write the
    // whole band to stdout again, and the frame after that a third time.
    var r = try makeRegion(2, .{ .interactive = false });
    defer r.deinit();
    try r.resize(4, Term.rows, 2);
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    try testing.expectEqualStrings("ab  \ncd  \n", t1.bytes());
    try testing.expect(!r.first_frame);

    // A height change after that frame: the pipe has said its one word.
    try r.setHeight(4);
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try testing.expectEqualStrings("", t2.bytes());

    // And a width change that carries a height change with it.
    try r.resize(8, Term.rows, 3);
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    try testing.expectEqualStrings("", t3.bytes());
    try testing.expect(!r.first_frame);
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
    try testing.expectEqual(@as(usize, 1), (try r.historyPending()).len);
    try testing.expectEqual(@as(usize, 0), q.pending());

    // The retry produces the complete frame.
    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    try testing.expectEqualStrings(
        sync_on ++ hide_c ++ aw_on ++ "queued\r\nledger\r\n" ++
            "\rab\r\ncd\r" ++ cpr_q ++ sync_off,
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
        sync_on ++ hide_c ++ aw_on ++ "\raaa\r\nbbb\r\nccc\r" ++ cpr_q ++ sync_off,
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
        sync_on ++ hide_c ++ aw_on ++ "L\r\n\rab\r\ncd\r" ++ cpr_q ++ sync_off,
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

test "region: queued lines land above the band in order, each exactly once" {
    // What the band does with a row written above it is consumer
    // visible: every queued line is on screen exactly once, IN THE ORDER
    // IT WAS QUEUED, and the live band sits below all of them —
    // no matter how many lines a single frame wrote.
    var r = try makeRegion(3, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "aaa");
    var term: Term = .{};
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());
    try testing.expectEqualStrings("aaa", term.text(0));

    try r.append(.{ .line = "one" });
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    term.feed(t2.bytes());
    try testing.expectEqualStrings("one", term.text(0));
    try testing.expectEqualStrings("aaa", term.text(1));

    try r.append(.{ .line = "two" });
    try r.append(.{ .line = "three" });
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    term.feed(t3.bytes());
    try testing.expectEqualStrings("one", term.text(0));
    try testing.expectEqualStrings("two", term.text(1));
    try testing.expectEqualStrings("three", term.text(2));
    try testing.expectEqualStrings("aaa", term.text(3));
    for ([_][]const u8{ "one", "two", "three", "aaa" }) |row| {
        try testing.expectEqual(@as(usize, 1), rowsHolding(&term, row));
    }
}

test "region: interleaved history and appends preserve submission order across frames" {
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try r.resize(10, Term.rows, 2);
    try tagRows(&r.cur, 2, 'a');
    var term: Term = .{};
    var out: TestWriter = .{};
    for (0..2) |frame| {
        const id: u64 = @intCast(frame * 2 + 1);
        try r.writeHistory(.{ .id = id, .rows = &.{"history-a"}, .kind = .append });
        try r.append(.{ .line = "append-a" });
        try r.writeHistory(.{ .id = id + 1, .rows = &.{"history-b"}, .kind = .append });
        try r.append(.{ .line = "append-b" });
        out.init();
        try r.render(&out.w);
        term.feed(out.bytes());
        for ([_][]const u8{ "history-a", "append-a", "history-b", "append-b" }, 0..) |row, y| {
            try testing.expectEqualStrings(row, term.text(frame * 4 + y));
        }
        try expectLabel(&term, frame * 4 + 4, 'a', 0);
        try expectLabel(&term, frame * 4 + 5, 'a', 1);
        // Leave the first frame's receipts retained while queue indices reset.
        try testing.expectEqual(@as(usize, frame * 2 + 2), r.history_written);
        try answerQuery(&r, &term);
    }
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4 }, r.acknowledgeDrained());
    out.init();
    try r.render(&out.w);
    try testing.expectEqualStrings("", out.bytes());
}

test "region: interleaved submission retry preserves both queues and screen order" {
    var r = try makeRegion(1, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "band");
    try r.writeHistory(.{ .id = 1, .rows = &.{"card"}, .kind = .append });
    try r.append(.{ .line = "next" });
    var short: [24]u8 = undefined;
    var failed: std.Io.Writer = .fixed(&short);
    try testing.expectError(error.WriteFailed, r.render(&failed));
    try testing.expectEqual(@as(usize, 0), r.history_written);
    try testing.expectEqual(@as(usize, 1), r.append_queue.items.len);
    var out: TestWriter = .{};
    out.init();
    try r.render(&out.w);
    var term: Term = .{};
    term.feed(out.bytes());
    try testing.expectEqualStrings("card", term.text(0));
    try testing.expectEqualStrings("next", term.text(1));
    try testing.expectEqualStrings("band", term.text(2));
}

test "region: piped interleaved submissions preserve order" {
    var r = try makeRegion(1, .{ .interactive = false });
    defer r.deinit();
    try r.resize(4, Term.rows, 1);
    try drawRow(&r.cur, 0, "band");
    try r.writeHistory(.{ .id = 1, .rows = &.{"card"}, .kind = .append });
    try r.append(.{ .line = "next" });
    try r.writeHistory(.{ .id = 2, .rows = &.{"diff"}, .kind = .append });
    try r.append(.{ .text = "last" });
    var out: TestWriter = .{};
    out.init();
    try r.render(&out.w);
    try testing.expectEqualStrings("card\nnext\ndiff\nlast\nband\n", out.bytes());
}

test "region: long line appends hard wrap with exact ledger and next frame anchor" {
    var r = try makeNativeRegion(2, .{}, 100);
    defer r.deinit();
    try r.resize(10, Term.rows, 2);
    try tagRows(&r.cur, 2, 'a');
    try r.append(.{ .line = "ABCDEFGHIJKLMNOPQRSTUVWXY" });
    var out: TestWriter = .{};
    out.init();
    try r.render(&out.w);
    var term: Term = .{};
    term.feed(out.bytes());
    try testing.expectEqualStrings("ABCDEFGHIJ", term.text(0));
    try testing.expectEqualStrings("KLMNOPQRST", term.text(1));
    try testing.expectEqualStrings("UVWXY", term.text(2));
    try expectLabel(&term, 3, 'a', 0);
    try expectLabel(&term, 4, 'a', 1);
    try testing.expectEqual(@as(usize, 3), r.pending_owned.items.len);
    for ([_]u16{ 10, 10, 5 }, r.pending_owned.items) |columns, row| {
        try testing.expectEqual(.committed, row.kind);
        try testing.expectEqual(columns, row.fp.columns);
    }
    try testing.expectEqual(@as(u16, 4), r.cursor_screen);
    try testing.expectEqual(@as(usize, 3), r.pending_rows);
    try answerQuery(&r, &term);
    try testing.expectEqual(@as(u16, 4), r.anchorRow());
    try drawRow(&r.cur, 1, "ZZ");
    out.init();
    try r.render(&out.w);
    term.feed(out.bytes());
    try testing.expectEqualStrings("ABCDEFGHIJ", term.text(0));
    try testing.expectEqualStrings("KLMNOPQRST", term.text(1));
    try testing.expectEqualStrings("UVWXY", term.text(2));
    try expectLabel(&term, 3, 'a', 0);
    try testing.expectEqualStrings("ZZ", term.text(4));
    try testing.expectEqual(@as(usize, 4), term.row);
    try testing.expectEqual(@as(usize, 0), term.col);
    out.init();
    try r.render(&out.w);
    try testing.expectEqualStrings("", out.bytes());
}

test "region: a styled line append wraps on visible columns, not escape bytes" {
    var r = try makeNativeRegion(1, .{}, 100);
    defer r.deinit();
    try r.resize(10, Term.rows, 1);
    try drawRow(&r.cur, 0, "band");
    // Twenty visible cells with SGR runs inside: two full rows, the reset
    // kept on the row it closes, no row split inside a sequence.
    try r.append(.{ .line = "\x1b[36mABCDE\x1b[0mFGHIJ\x1b[1mKLMNOPQRST\x1b[0m" });
    var out: TestWriter = .{};
    out.init();
    try r.render(&out.w);
    var term: Term = .{};
    term.feed(out.bytes());
    try testing.expectEqualStrings("ABCDEFGHIJ", term.text(0));
    try testing.expectEqualStrings("KLMNOPQRST", term.text(1));
    try testing.expectEqualStrings("band", term.text(2));
    try testing.expectEqual(@as(usize, 2), r.pending_rows);
}

test "region: line append newlines split rows without raw LF or phantom trailing row" {
    var r = try makeNativeRegion(1, .{}, 100);
    defer r.deinit();
    try r.resize(4, Term.rows, 1);
    try drawRow(&r.cur, 0, "band");
    try r.append(.{ .line = "abcdef\n\nxy\n" });
    var out: TestWriter = .{};
    out.init();
    try r.render(&out.w);
    var term: Term = .{};
    term.feed(out.bytes());
    for ([_][]const u8{ "abcd", "ef", "", "xy", "band" }, 0..) |row, y| {
        try testing.expectEqualStrings(row, term.text(y));
    }
    try testing.expectEqual(@as(usize, 4), r.pending_rows);
    try testing.expectEqual(@as(u16, 4), r.cursor_screen);
}

test "region: line hard wrapping follows terminal cell mode and wide cluster boundaries" {
    const saved = Width.getMode();
    defer Width.setMode(saved);
    for ([_]Width.Mode{ .grapheme, .codepoint }) |mode| {
        Width.setMode(mode);
        var r = try makeNativeRegion(1, .{}, 100);
        defer r.deinit();
        try r.resize(3, Term.rows, 1);
        try r.append(.{ .line = "ab界e\u{301}👨‍🌾!" });
        var out: TestWriter = .{};
        out.init();
        try r.render(&out.w);
        const expected = if (mode == .grapheme)
            "ab\r\n界e\u{301}\r\n👨‍🌾!\r\n"
        else
            "ab\r\n界e\u{301}\r\n👨‍\r\n🌾!\r\n";
        try testing.expect(std.mem.indexOf(u8, out.bytes(), expected) != null);
        const rows: usize = if (mode == .grapheme) 3 else 4;
        try testing.expectEqual(rows, r.pending_rows);
        try testing.expectEqual(@as(u16, @intCast(rows)), r.cursor_screen);
    }
}

test "region: grow reserves the new rows even without append_lines" {
    // The reservation is physical whatever the first frame did: a band
    // row that does not exist on screen cannot be painted, so the rows
    // the band gained are created below it and the rows it already owned
    // keep their content and their place.
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try tagRows(&r.cur, 2, 'a');
    var term: Term = .{};
    feedHistory(&term);
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());
    try testing.expectEqual(@as(usize, 6), term.row);

    try r.setHeight(4);
    try drawRow(&r.cur, 2, label('b', 0)); // only the rows it gained
    try drawRow(&r.cur, 3, label('b', 1));
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    term.feed(t2.bytes());
    // Exactly the two rows it gained were added, and nothing above them
    // moved.
    for (history_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.text(y));
    for (0..2) |y| try expectLabel(&term, 5 + y, 'a', y);
    for (0..2) |y| try expectLabel(&term, 7 + y, 'b', y);
    try testing.expectEqual(@as(usize, 8), term.row);
    try testing.expectEqual(@as(u16, 4), r.painted_rows);
    try testing.expect(!r.height_dirty);
    // Row-scoped: no ED0, so nothing above the band is ever erased.
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "\x1b[J"));
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

test "region: a height that returns to the painted extent moves nothing" {
    // The REPL popup opens and closes inside ONE tick, so a frame can
    // settle on a height the band already occupies. Moving the terminal
    // by the LAST call's delta instead would push the band down and
    // strand blank rows above it: the band no longer owns those rows,
    // so no later frame may erase them.
    var r = try makeRegion(10, .{});
    defer r.deinit();
    try tagRows(&r.cur, 10, 'a');
    var term: Term = .{};
    feedHistory(&term);
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());
    // Five transcript rows, then a ten-row band: rows 5..14.
    try testing.expectEqual(@as(usize, 14), term.row);
    try testing.expectEqual(@as(u16, 10), r.painted_rows);

    // The drawing buffer is reshaped by each call, and a reshape keeps
    // only the rows the two heights have in common: the app lays the band
    // out again for the height it settled on, exactly as a real frame
    // does after any height change.
    try r.setHeight(2);
    try r.setHeight(10);
    try tagRows(&r.cur, 10, 'a');
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    term.feed(t2.bytes());
    // Net zero: no reservation, no erase, no repaint.
    try testing.expectEqualStrings("", t2.bytes());
    try testing.expectEqual(@as(usize, 14), term.row);
    try testing.expectEqual(@as(u16, 10), r.painted_rows);
    for (history_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.text(y));
    for (0..10) |y| try expectLabel(&term, 5 + y, 'a', y);

    // The next real frame paints the rows the band owns, from its own
    // top, and the transcript above them is untouched.
    try tagRows(&r.cur, 10, 'b');
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    term.feed(t3.bytes());
    for (history_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.text(y));
    for (0..10) |y| try expectLabel(&term, 5 + y, 'b', y);
    try testing.expectEqual(@as(usize, 14), term.row);
    try testing.expectEqual(@as(u16, 10), r.painted_rows);
}

test "region: a coalesced height shrink erases only the net tail" {
    // 10 -> 2 -> 7 leaves three rows fewer than the band owns. The frame
    // must erase exactly those three, row-scoped, and repaint the seven
    // the band still owns: a walk by the last call's delta strands the
    // removed rows' text and paints the band that far down.
    var r = try makeRegion(10, .{});
    defer r.deinit();
    try tagRows(&r.cur, 10, 'a');
    var term: Term = .{};
    feedHistory(&term);
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());
    try testing.expectEqual(@as(usize, 14), term.row);

    try r.setHeight(2);
    try r.setHeight(7);
    try tagRows(&r.cur, 7, 'b');
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    term.feed(t2.bytes());
    for (history_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.text(y));
    for (0..7) |y| try expectLabel(&term, 5 + y, 'b', y);
    // The released rows are blanked: a row the band gives up is erased
    // row-scoped, never left holding the frame it used to show.
    try testing.expectEqualStrings("", term.text(12));
    try testing.expectEqualStrings("", term.text(13));
    try testing.expectEqualStrings("", term.text(14));
    try testing.expectEqual(@as(usize, 11), term.row);
    try testing.expectEqual(@as(u16, 7), r.painted_rows);
    // Row-scoped all the way: a height change never issues ED0.
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "\x1b[J"));
}

test "region: a width-preserving physical shrink keeps the rows the band owns" {
    // The REPL's first width-preserving shrink (97x28 -> 97x6). A
    // physical shrink keeps the cursor's line and scrolls the rest into
    // scrollback, so the band's top rows leave the screen and no
    // relative move reaches them again. The app asks for a six-row band
    // and redraws it — and five of the six rows come back BYTE-IDENTICAL
    // to what the band already held, because a shorter popup only moves
    // the status line. Those rows are no longer on the screen, though:
    // the frame has to repaint every surviving row, or the band shows
    // whatever the scrolled-in rows happened to say.
    const tall_band = [_][]const u8{
        "input> d",
        "> def",
        "  defn",
        "  deg->rad",
        "  deriv",
        "  diff",
        "  disasm",
        "  display",
        "  dot",
        "status",
    };
    const short_band = [_][]const u8{
        "input> d",
        "> def",
        "  defn",
        "  deg->rad",
        "  deriv",
        "status",
    };
    var r = try makeRegion(tall_band.len, .{});
    defer r.deinit();
    for (tall_band, 0..) |row, y| try drawRow(&r.cur, @intCast(y), row);

    var term: Term = .{};
    feedHistory(&term);
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());
    // Five committed rows, then a ten-row band: rows 5..14.
    try testing.expectEqual(@as(usize, 14), term.row);
    try testing.expectEqual(@as(u16, 10), r.painted_rows);

    // The physical shrink: not a byte on the wire and not a width
    // change — the screen simply has six rows now, and the band rows
    // above its new top are scrollback no cursor move can reach. The
    // call below is the app's winsize handler: terminal columns, the six
    // rows now visible and the band height it recomputes for them.
    term.resizeRows(6);
    try r.resize(80, 6, @intCast(short_band.len));
    for (short_band, 0..) |row, y| try drawRow(&r.cur, @intCast(y), row);
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    term.feed(t2.bytes());

    // All six live rows show the band, top to bottom: the input line
    // first, the selected candidate under it, the status line last.
    for (short_band, 0..) |row, y| try testing.expectEqualStrings(row, term.screenText(y));
    // Parked on the owned bottom row: where the next frame's relative
    // moves start from.
    try testing.expectEqual(@as(usize, short_band.len - 1), term.screenRow());
    try testing.expectEqual(@as(usize, 0), term.col);
    try testing.expectEqual(@as(u16, 6), r.painted_rows);
    // The committed transcript scrolled; nothing erased it.
    for (history_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.text(y));
}

test "region: a physical shrink past the new band top blanks what it gives up" {
    // 24 -> 8 rows under a ten-row band: the band's top two rows scroll
    // into scrollback, the app asks for four rows, and three of the four
    // it keeps come back byte-identical to what is already on screen.
    // The band re-bases on the cursor — its top moves DOWN by six — so
    // the rows between the viewport top and the new band top are rows
    // the band no longer owns and must not keep holding the frame they
    // used to show.
    var r = try makeRegion(10, .{});
    defer r.deinit();
    try tagRows(&r.cur, 10, 'a');
    var term: Term = .{};
    feedHistory(&term);
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());
    // Five transcript rows, then a ten-row band: rows 5..14.
    try testing.expectEqual(@as(usize, 14), term.row);
    try testing.expectEqual(@as(u16, 10), r.painted_rows);

    term.resizeRows(8);
    try r.resize(80, 8, 4);
    try tagRows(&r.cur, 4, 'b');
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    term.feed(t2.bytes());

    // The screen shows rows 7..14: four released rows blanked, then the
    // four-row band at its own rows, parked on the owned bottom.
    for (7..11) |row| try testing.expectEqualStrings("", term.text(row));
    for (0..4) |y| try expectLabel(&term, 11 + y, 'b', y);
    try testing.expectEqual(@as(usize, 14), term.row);
    try testing.expectEqual(@as(usize, 0), term.col);
    try testing.expectEqual(@as(u16, 4), r.painted_rows);
    // The transcript never moved and never got erased.
    for (history_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.text(y));
    // Row-scoped all the way: the re-base never reaches above it, so no
    // ED0 and no ED2 — the scrollback above the band is untouched.
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "\x1b[J"));
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "\x1b[2J"));

    // The re-based band is the band: the next content change lands on
    // its rows, not on the rows the band used to own.
    try tagRows(&r.cur, 4, 'c');
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    term.feed(t3.bytes());
    for (0..4) |y| try expectLabel(&term, 11 + y, 'c', y);
    for (history_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.text(y));
    try testing.expectEqual(@as(usize, 14), term.row);

    // The re-base retired the reach, and so did the reply the FIRST frame
    // asked for: a geometry change under it makes that answer name rows
    // the region has stopped tracking, so it is DISCARDED and the
    // measurement still stands. Discarding it is what frees the single
    // query slot, and the frame that spends it says exactly one fresh
    // postpaint query, the park every painter leaves behind, and the
    // envelope around them — no row, no move. A measurement frame that
    // rewrote the band would be the drift this protocol exists to stop.
    try answerQuery(&r, &term);
    var t4: TestWriter = .{};
    t4.init();
    try r.render(&t4.w);
    try testing.expectEqualStrings(framed("\r" ++ cpr_q), t4.bytes());
    term.feed(t4.bytes());
    for (0..4) |y| try expectLabel(&term, 11 + y, 'c', y);

    // Measured at last, from the model's own cursor. Nothing is owed now,
    // and a frame with nothing left to say emits zero bytes — envelope
    // included — while the band holds the frame before it.
    try answerQuery(&r, &term);
    var t5: TestWriter = .{};
    t5.init();
    try r.render(&t5.w);
    try testing.expectEqualStrings("", t5.bytes());
    for (0..4) |y| try expectLabel(&term, 11 + y, 'c', y);
}

test "region: a coalesced height growth reserves only the net rows" {
    // 2 -> 5 -> 3 grows the band by ONE row. A frame that believed it
    // had lost two walks the cursor two rows above the band top and
    // paints the settled transcript above it.
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try tagRows(&r.cur, 2, 'a');
    var term: Term = .{};
    feedHistory(&term);
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());
    try testing.expectEqual(@as(usize, 6), term.row);

    try r.setHeight(5);
    try r.setHeight(3);
    try tagRows(&r.cur, 3, 'b');
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    term.feed(t2.bytes());
    // Exactly one row is reserved: a band row that does not exist on
    // screen cannot be painted. The band owns rows 5..7 and nothing
    // below them, so the reservation was the net gain and no more.
    for (history_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.text(y));
    for (0..3) |y| try expectLabel(&term, 5 + y, 'b', y);
    try testing.expectEqualStrings("", term.text(8));
    try testing.expectEqual(@as(usize, 7), term.row);
    try testing.expectEqual(@as(u16, 3), r.painted_rows);
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "\x1b[J"));
}

test "region: a band that grows onto the last screen row scrolls, never overwrites" {
    // A REPL prompt at the bottom of a full screen: the two-row band sits
    // on the screen's LAST row, with a committed transcript filling
    // every row above it. A cursor move stops at the last visible row,
    // so the reservation has to be a real newline: the terminal, not the
    // region, decides that the screen gives up rows at the TOP (into
    // scrollback, where the transcript is kept), and no frame may repaint
    // a row the band or the transcript already owns.
    const band_top = Term.rows - 2; // the band's first row: the last two screen rows
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try tagRows(&r.cur, 2, 'a');
    var term: Term = .{};
    feedTranscript(&term, band_top);
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());

    // The starting state: a full screen of transcript, then the two band
    // rows on its last two rows, cursor parked on the band bottom.
    for (0..band_top) |y| {
        try testing.expectEqualStrings(transcriptRow(y), term.screenText(y));
    }
    for (0..2) |y| try testing.expectEqualStrings(label('a', y), term.screenText(band_top + y));
    try testing.expectEqual(@as(usize, Term.rows - 1), term.screenRow());
    try testing.expectEqual(@as(usize, 0), term.col);
    try expectTranscriptIntact(&term);

    // The app grows the band and fills only the two rows it gained; the
    // two it already had keep their text.
    try r.setHeight(4);
    try drawRow(&r.cur, 2, label('b', 2));
    try drawRow(&r.cur, 3, label('b', 3));
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    term.feed(t2.bytes());

    // All four owned rows are on the screen, in order, ending on the
    // screen's last row: the band's bottom row was there before the
    // growth and nothing may push it off the bottom.
    try testing.expectEqual(@as(u16, 4), r.painted_rows);
    for (0..2) |y| {
        try testing.expectEqualStrings(label('a', y), term.screenText(Term.rows - 4 + y));
        try testing.expectEqualStrings(label('b', 2 + y), term.screenText(Term.rows - 2 + y));
    }
    // Parked on the owned bottom row, where the next frame's relative
    // moves start from.
    try testing.expectEqual(@as(usize, Term.rows - 1), term.screenRow());
    try testing.expectEqual(@as(usize, 0), term.col);

    // Every committed row is still in the terminal's buffer, in order,
    // and none of them lost its text to a band row: the rows the screen
    // gave up are the transcript's first rows, and they read exactly
    // where the scroll put them.
    const kept = Term.rows - 4; // transcript rows still on screen
    for (0..kept) |y| {
        try testing.expectEqualStrings(
            transcriptRow(transcript.len - kept + y),
            term.screenText(y),
        );
    }
    try expectTranscriptIntact(&term);

    // The band is still the band: an edit to its first row lands on that
    // row, the other three keep their text, and the transcript above is
    // untouched.
    try clearRow(&r.cur, 0, 2);
    try drawRow(&r.cur, 0, "ZZ");
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    term.feed(t3.bytes());

    try testing.expectEqualStrings("ZZ", term.screenText(Term.rows - 4));
    try testing.expectEqualStrings(label('a', 1), term.screenText(Term.rows - 3));
    try testing.expectEqualStrings(label('b', 2), term.screenText(Term.rows - 2));
    try testing.expectEqualStrings(label('b', 3), term.screenText(Term.rows - 1));
    try testing.expectEqual(@as(usize, Term.rows - 1), term.screenRow());
    for (0..kept) |y| {
        try testing.expectEqualStrings(
            transcriptRow(transcript.len - kept + y),
            term.screenText(y),
        );
    }
    try expectTranscriptIntact(&term);
    // Nothing is owed after that: the band is where the region believes
    // it is, so a frame with nothing to say emits zero bytes.
    var t4: TestWriter = .{};
    t4.init();
    try r.render(&t4.w);
    try testing.expectEqualStrings("", t4.bytes());
}

test "region: a popup that fills a short screen keeps the rows it scrolls past" {
    // The short terminal the REPL really runs in: a candidate popup wants
    // every row a six-row window has, with four committed transcript
    // rows above the live input and status rows. A band that cannot be
    // reserved below has to take those four rows into scrollback — the
    // popup itself looks right either way, so what this pins down is the
    // committed text a growth must never paint over.
    const live = 4; // committed rows the six-row window still shows
    const screen = live + 2; // the window: history, input row, status row
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try tagRows(&r.cur, 2, 'a');
    var term: Term = .{};
    feedTranscript(&term, Term.rows - 2);
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());

    // The window is dragged down to six rows. A physical shrink keeps
    // the cursor's line, so the live rows are the last six the band and
    // the transcript left behind; the app reports the size it recomputed.
    term.resizeRows(screen);
    try r.resize(Term.cols, screen, 2);
    for (0..live) |y| {
        try testing.expectEqualStrings(
            transcriptRow(transcript.len - live + y),
            term.screenText(y),
        );
    }
    for (0..2) |y| try testing.expectEqualStrings(label('a', y), term.screenText(live + y));
    try testing.expectEqual(@as(usize, screen - 1), term.screenRow());
    try testing.expectEqual(@as(usize, 0), term.col);
    try expectTranscriptIntact(&term);

    // Typing opens the popup: six rows, every one of them redrawn, the
    // live input line first.
    try r.setHeight(6);
    try tagRows(&r.cur, 6, 'b');
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    term.feed(t2.bytes());

    // The popup owns the whole window, top to bottom.
    try testing.expectEqual(@as(u16, 6), r.painted_rows);
    for (0..6) |y| try testing.expectEqualStrings(label('b', y), term.screenText(y));
    try testing.expectEqual(@as(usize, screen - 1), term.screenRow());
    try testing.expectEqual(@as(usize, 0), term.col);
    // The rows the popup could only reach by scrolling are committed
    // history: in the terminal's buffer, never repainted.
    try expectTranscriptIntact(&term);

    // The next keystroke edits the live input row: it lands on the
    // window's first row and nothing else moves.
    try clearRow(&r.cur, 0, 2);
    try drawRow(&r.cur, 0, "ZZ");
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    term.feed(t3.bytes());

    try testing.expectEqualStrings("ZZ", term.screenText(0));
    for (1..6) |y| try testing.expectEqualStrings(label('b', y), term.screenText(y));
    try testing.expectEqual(@as(usize, screen - 1), term.screenRow());
    try expectTranscriptIntact(&term);
    // Nothing is owed after that: the band is where the region believes
    // it is, so a frame with nothing to say emits zero bytes.
    var t4: TestWriter = .{};
    t4.init();
    try r.render(&t4.w);
    try testing.expectEqualStrings("", t4.bytes());
}

test "region: a restored viewport never shows the rows a physical shrink took from the band" {
    // The captured run: a 28-row window dragged down to six, three, two
    // and one row, then back out to six and to the full height. A
    // physical shrink keeps the cursor's line, so the popup walks off the
    // screen one row at a time and the rows it left behind are the
    // terminal's scrollback. A GROWTH hands that scrollback back to the
    // screen: when the window is six rows again and then full height
    // again, the rows this band painted and gave up are on screen once
    // more, ABOVE the live popup. Nothing committed them and no frame
    // has claimed them since.
    //
    // What the user reads at the end is two things and nothing else: the
    // live popup is the band, and the committed transcript is still in
    // the terminal's buffer, once each. The rows between them are the
    // band's own residue, and taking them back must not reach a row
    // above the band that holds committed text.
    const committed = Term.rows - popup_rows.len; // transcript above the band
    const band_top = committed; // the live popup's first screen row
    var r = try makeRegion(@intCast(popup_rows.len), .{});
    defer r.deinit();
    try drawPopup(&r.cur, @intCast(popup_rows.len));
    var term: Term = .{};
    feedTranscript(&term, committed);
    var open: TestWriter = .{};
    open.init();
    try r.render(&open.w);
    term.feed(open.bytes());
    try answerQuery(&r, &term);

    // Where the run starts: a committed transcript filling the screen
    // above the band, then the popup on its last six rows.
    for (0..committed) |y| try testing.expectEqualStrings(transcriptRow(y), term.screenText(y));
    for (popup_rows, 0..) |row, y| {
        try testing.expectEqualStrings(row, term.screenText(band_top + y));
    }
    try testing.expectEqual(@as(usize, Term.rows - 1), term.screenRow());

    // The window is dragged shorter and the app re-lays the popup into
    // the rows it keeps: 6 -> 3 -> 2 -> 1. Each step is a physical
    // resize beside the height the app recomputed for it.
    for ([_]u16{ 3, 2, 1 }) |rows| {
        term.resizeRows(rows);
        try r.resize(Term.cols, rows, rows);
        try drawPopup(&r.cur, rows);
        var shorter: TestWriter = .{};
        shorter.init();
        try r.render(&shorter.w);
        term.feed(shorter.bytes());
        // Each step's own query is answered, so the next geometry change
        // starts from a free slot and can ask again.
        try answerQuery(&r, &term);

        // The popup is all the window holds, live input row first and
        // status row last, whatever the window is now.
        for (0..@as(usize, rows)) |y| {
            try testing.expectEqualStrings(popup_rows[y], term.screenText(y));
        }
        try testing.expectEqual(@as(usize, rows - 1), term.screenRow());
        try testing.expectEqual(rows, r.painted_rows);
        // The rows that left the screen are the terminal's scrollback
        // now: the committed transcript is in the buffer whatever the
        // screen did with it.
        for (0..committed) |y| {
            try testing.expectEqual(@as(usize, 1), rowsHolding(&term, transcriptRow(y)));
        }
    }

    // The window grows back to the popup's six rows. The rows the band
    // gave up on the way down are on screen again, and the band reserves
    // its own rows and repaints over the top of the window.
    term.resizeRows(popup_rows.len);
    try r.resize(Term.cols, popup_rows.len, @intCast(popup_rows.len));
    try drawPopup(&r.cur, @intCast(popup_rows.len));
    var wide: TestWriter = .{};
    wide.init();
    try r.render(&wide.w);
    term.feed(wide.bytes());
    try answerQuery(&r, &term);
    for (popup_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.screenText(y));
    try testing.expectEqual(@as(usize, popup_rows.len - 1), term.screenRow());
    try testing.expectEqual(@as(u16, popup_rows.len), r.painted_rows);

    // The window is dragged back to its full height — the state the
    // capture caught. The terminal hands its scrollback back to the
    // screen, and what comes back above the live band is committed
    // transcript: thirteen rows this run wrote before the band ever
    // existed, on the screen again. That is the physical fact the frame
    // below has to answer, and a model that kept those rows in
    // scrollback would make every assertion after it vacuous.
    // The returned retired prefix is still directly above the band.
    // After CPR measures it, reclamation closes that gap without moving
    // any of the committed rows the terminal handed back.
    term.resizeRows(Term.rows);
    const transcript_back = 13; // of the pull's 18 rows, 5 were the band's own
    for (0..transcript_back) |y| {
        try testing.expectEqualStrings(
            transcriptRow(committed - transcript_back + y),
            term.screenText(y),
        );
    }
    try r.resize(Term.cols, Term.rows, @intCast(popup_rows.len));
    var restored: TestWriter = .{};
    restored.init();
    try r.render(&restored.w);
    term.feed(restored.bytes());
    // The restore's own frame could not know how far up the retired rows
    // still were: a geometry change retires the reach, and no erase runs
    // on a guess. Its query is answered from the model's real cursor, and
    // the frame after THAT is the one that may take the rows back.
    try answerQuery(&r, &term);
    var reclaimed: TestWriter = .{};
    reclaimed.init();
    try r.render(&reclaimed.w);
    term.feed(reclaimed.bytes());

    // The five returned prefix rows rejoin the band, so it starts
    // directly below the thirteen visible committed rows again.
    const reclaimed_top = transcript_back;
    for (popup_rows, 0..) |row, y| {
        try testing.expectEqualStrings(row, term.screenText(reclaimed_top + y));
    }
    try testing.expectEqual(reclaimed_top + popup_rows.len - 1, term.screenRow());
    try testing.expectEqual(@as(u16, popup_rows.len), r.painted_rows);
    // The rows the window handed back above it hold no popup text at
    // all — the archived input row and the archived selected candidate
    // the capture showed above the live band are the residue here, and
    // the live popup is the only owner of those strings.
    try testing.expectEqual(@as(usize, 0), restoredBandRows(&term, reclaimed_top, &popup_rows));
    // The committed transcript took none of it: every row is still in
    // the terminal's buffer exactly once, so taking the band's residue
    // back did not reach a row above the band that holds history.
    for (0..committed) |y| {
        try testing.expectEqual(@as(usize, 1), rowsHolding(&term, transcriptRow(y)));
    }

    // And the next keystroke still belongs to the live band: it lands on
    // the popup's input row, the rows above keep no band text, and the
    // committed rows are still in the buffer.
    try drawRow(&r.cur, 0, "skript> de");
    var edit: TestWriter = .{};
    edit.init();
    try r.render(&edit.w);
    term.feed(edit.bytes());
    try testing.expectEqualStrings("skript> de", term.screenText(reclaimed_top));
    for (popup_rows[1..], 0..) |row, y| {
        try testing.expectEqualStrings(row, term.screenText(reclaimed_top + 1 + y));
    }
    try testing.expectEqual(@as(usize, 0), restoredBandRows(&term, reclaimed_top, &popup_rows));
    try testing.expectEqual(reclaimed_top + popup_rows.len - 1, term.screenRow());
    for (0..committed) |y| {
        try testing.expectEqual(@as(usize, 1), rowsHolding(&term, transcriptRow(y)));
    }
}

test "region: a window restored with no scrollback left keeps the band on its line" {
    // The growth a restored popup takes when the window runs out of
    // scrollback before it runs out of rows. A session that never filled
    // its window starts with the prompt high on it: the launcher printed
    // two rows, the band took six, and the rest of the window is empty.
    // The window is then dragged down to a single row, which scrolls the
    // band's top rows into scrollback, and dragged back out to its full
    // height.
    //
    // The scrollback that window can be handed back is the seven rows
    // above the one-row window and nothing more, so the terminal adds
    // the other sixteen BELOW the cursor's line, empty, and the band
    // keeps the row it was on instead of being pushed to the new bottom —
    // the 97x28 capture, where the live band sat at rows 8..13 of 28.
    // Above it, the rows the band gave up on the way down are on the
    // screen again: the retired live rows the frame below has to answer
    // for.
    const history = 2; // committed rows above the band when the session starts
    var r = try makeRegion(@intCast(popup_rows.len), .{});
    defer r.deinit();
    try drawPopup(&r.cur, @intCast(popup_rows.len));
    var term: Term = .{};
    feedTranscript(&term, history);
    var open: TestWriter = .{};
    open.init();
    try r.render(&open.w);
    term.feed(open.bytes());
    try answerQuery(&r, &term);

    // The session as it starts: the committed rows and the popup at the
    // top of a window still mostly empty below them.
    for (0..history) |y| try testing.expectEqualStrings(transcriptRow(y), term.screenText(y));
    for (popup_rows, 0..) |row, y| {
        try testing.expectEqualStrings(row, term.screenText(history + y));
    }
    try testing.expectEqual(@as(usize, history + popup_rows.len - 1), term.screenRow());

    // The window is dragged down to one row: the band gives up all but
    // its last row, and that row is all the window still shows.
    term.resizeRows(1);
    try r.resize(Term.cols, 1, 1);
    try drawPopup(&r.cur, 1);
    var one_row: TestWriter = .{};
    one_row.init();
    try r.render(&one_row.w);
    term.feed(one_row.bytes());
    try answerQuery(&r, &term);
    try testing.expectEqualStrings(popup_rows[0], term.screenText(0));
    try testing.expectEqual(@as(usize, 0), term.screenRow());

    // The window is dragged back to its full height. The rows below the
    // cursor's line are new and empty, the cursor's line keeps its place,
    // and the retired live rows are on the screen again — the physical
    // fact the frame below has to answer, and what makes the assertions
    // after it non-vacuous.
    const band_top = history + popup_rows.len - 1; // the live band's screen row
    term.resizeRows(Term.rows);
    try testing.expect(restoredBandRows(&term, band_top, &popup_rows) > 0);
    try testing.expectEqual(@as(usize, band_top), term.screenRow());
    for (band_top + 1..Term.rows) |y| try testing.expectEqualStrings("", term.screenText(y));

    try r.resize(Term.cols, Term.rows, @intCast(popup_rows.len));
    try drawPopup(&r.cur, @intCast(popup_rows.len));
    var restored: TestWriter = .{};
    restored.init();
    try r.render(&restored.w);
    term.feed(restored.bytes());
    // The restore retires the reach, so this frame could not walk up to
    // the rows it gave up on the way down; its own reply measures them
    // and the next frame takes them back, row-scoped.
    try answerQuery(&r, &term);
    var reclaimed: TestWriter = .{};
    reclaimed.init();
    try r.render(&reclaimed.w);
    term.feed(reclaimed.bytes());

    // Reclaim the five returned prefix rows, directly below the history.
    // The old band's now-unused bottom rows are empty.
    for (popup_rows, 0..) |row, y| {
        try testing.expectEqualStrings(row, term.screenText(history + y));
    }
    try testing.expectEqual(@as(usize, history + popup_rows.len - 1), term.screenRow());
    try testing.expectEqual(@as(u16, popup_rows.len), r.painted_rows);
    for (history + popup_rows.len..Term.rows) |y| {
        try testing.expectEqualStrings("", term.screenText(y));
    }
    try testing.expectEqual(@as(usize, 0), restoredBandRows(&term, history, &popup_rows));
    // The committed rows the growth handed back to the screen are
    // untouched by any of it.
    for (0..history) |y| {
        try testing.expectEqual(@as(usize, 1), rowsHolding(&term, transcriptRow(y)));
    }
}

test "region: history committed on a one-row viewport survives the window's restoration" {
    // The same shrink-and-restore run with output in it. The window is
    // one row tall when the app commits two rows, and a one-row window
    // has nowhere to put them but the scrollback above the band: that is
    // where a commit lands on a short viewport, and they are committed
    // rows there like any other.
    //
    // Restoring the window hands that scrollback back, and what comes back
    // together with the rows the band gave up is those two rows, sitting
    // between the retired live rows and the live band. Taking the band's
    // residue back has to leave them alone: a fix that cleared one
    // contiguous span from the earliest row the band ever owned would take
    // them — and the transcript between them — with it.
    const committed = Term.rows - popup_rows.len; // transcript above the band
    const band_top = Term.rows - popup_rows.len; // the live band's screen row, restored
    var r = try makeRegion(@intCast(popup_rows.len), .{});
    defer r.deinit();
    try drawPopup(&r.cur, @intCast(popup_rows.len));
    var term: Term = .{};
    feedTranscript(&term, committed);
    var open: TestWriter = .{};
    open.init();
    try r.render(&open.w);
    term.feed(open.bytes());
    try answerQuery(&r, &term);

    for ([_]u16{ 3, 2, 1 }) |rows| {
        term.resizeRows(rows);
        try r.resize(Term.cols, rows, rows);
        try drawPopup(&r.cur, rows);
        var shorter: TestWriter = .{};
        shorter.init();
        try r.render(&shorter.w);
        term.feed(shorter.bytes());
        try answerQuery(&r, &term);
    }

    // The commit happens with the window one row tall: the frame writes
    // the batch above the band top, so both rows land in the scrollback
    // the one-row window cannot show, and the live input row stays the
    // only thing the window holds.
    const late_rows = [_][]const u8{ "t90", "t91" };
    _ = try r.writeTranscript(&late_rows);
    var commit: TestWriter = .{};
    commit.init();
    try r.render(&commit.w);
    term.feed(commit.bytes());
    try answerQuery(&r, &term);
    try testing.expectEqualStrings(popup_rows[0], term.screenText(0));
    for (late_rows) |row| try testing.expectEqual(@as(usize, 1), rowsHolding(&term, row));

    // The window opens back to the popup's six rows: the band takes the
    // whole window, and the committed rows stay where the flush put them.
    term.resizeRows(popup_rows.len);
    try r.resize(Term.cols, popup_rows.len, @intCast(popup_rows.len));
    try drawPopup(&r.cur, @intCast(popup_rows.len));
    var wide: TestWriter = .{};
    wide.init();
    try r.render(&wide.w);
    term.feed(wide.bytes());
    try answerQuery(&r, &term);
    for (popup_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.screenText(y));
    try testing.expectEqual(@as(usize, popup_rows.len - 1), term.screenRow());

    // And the window is dragged back to its full height: the screen shows
    // the retired live rows, then the two committed rows the one-row
    // window pushed into scrollback, then the live band.
    term.resizeRows(Term.rows);
    try testing.expect(restoredBandRows(&term, band_top, &popup_rows) > 0);
    for (late_rows, 0..) |row, y| {
        try testing.expectEqualStrings(row, term.screenText(band_top - 2 + y));
    }
    try r.resize(Term.cols, Term.rows, @intCast(popup_rows.len));
    var restored: TestWriter = .{};
    restored.init();
    try r.render(&restored.w);
    term.feed(restored.bytes());
    // The restore retires the reach: the retired popup rows the pull put
    // back on the screen cannot be walked to on a guess. The frame's own
    // reply measures them and the next one takes exactly those rows back
    // — the two committed rows between them and the band stay put.
    try answerQuery(&r, &term);
    var reclaimed: TestWriter = .{};
    reclaimed.init();
    try r.render(&reclaimed.w);
    term.feed(reclaimed.bytes());

    // The live band is the band, on the window's last rows, with the
    // cursor parked on the row the next frame's relative moves start from.
    for (popup_rows, 0..) |row, y| {
        try testing.expectEqualStrings(row, term.screenText(band_top + y));
    }
    try testing.expectEqual(@as(usize, Term.rows - 1), term.screenRow());
    try testing.expectEqual(@as(u16, popup_rows.len), r.painted_rows);
    // No band row of its own survives above it...
    try testing.expectEqual(@as(usize, 0), restoredBandRows(&term, band_top, &popup_rows));
    // ...and every committed row is still in the terminal's buffer exactly
    // once: the transcript's own, and the two the one-row window took.
    for (0..committed) |y| {
        try testing.expectEqual(@as(usize, 1), rowsHolding(&term, transcriptRow(y)));
    }
    for (late_rows) |row| try testing.expectEqual(@as(usize, 1), rowsHolding(&term, row));
}

test "region: a window restored under a dismissed band shows nothing new" {
    // The growth that must NOT pull scrollback. A popup physically
    // clipped into a three-row window and then logically dismissed to one
    // row parks the cursor two rows up, with the blank tail it erased
    // under it. A window dragged out to full height from there grows
    // DOWNWARD — xterm's observed `Buffer.resize` appends blank lines
    // below the cursor and leaves `ybase`/`ydisp` alone — so the viewport
    // top does not move, the band keeps the screen row it was on, and
    // nothing above it changes. Nothing may be erased there, and the rows
    // an earlier clip retired stay TRACKED rather than assumed reclaimed:
    // a later pull brings them back and the region has to take them back
    // then.
    const history = 6; // committed rows above the band when it opens
    var r = try makeRegion(@intCast(popup_rows.len), .{});
    defer r.deinit();
    try drawPopup(&r.cur, @intCast(popup_rows.len));
    var term: Term = .{};
    feedTranscript(&term, history);
    var open: TestWriter = .{};
    open.init();
    try r.render(&open.w);
    term.feed(open.bytes());
    try answerQuery(&r, &term);
    for (0..history) |y| try testing.expectEqualStrings(transcriptRow(y), term.screenText(y));
    for (popup_rows, 0..) |row, y| {
        try testing.expectEqualStrings(row, term.screenText(history + y));
    }

    // A physical clip to three rows re-bases the band onto two: one of
    // its rows is erased in place, the rest leaves the screen entirely.
    term.resizeRows(3);
    try r.resize(Term.cols, 3, 2);
    try drawPopup(&r.cur, 2);
    var clipped: TestWriter = .{};
    clipped.init();
    try r.render(&clipped.w);
    term.feed(clipped.bytes());
    try answerQuery(&r, &term);
    try testing.expectEqualStrings("", term.screenText(0));
    for (0..2) |y| try testing.expectEqualStrings(popup_rows[y], term.screenText(1 + y));
    try testing.expectEqual(@as(usize, 2), term.screenRow());

    // The popup is dismissed while the window stays three rows: the band
    // keeps its first row, the row it released is erased, and the cursor
    // is parked a row above the window's last one — a blank tail under it.
    try r.setHeight(1);
    var dismissed: TestWriter = .{};
    dismissed.init();
    try r.render(&dismissed.w);
    term.feed(dismissed.bytes());
    try answerQuery(&r, &term);
    try testing.expectEqualStrings(popup_rows[0], term.screenText(1));
    try testing.expectEqualStrings("", term.screenText(2));
    try testing.expectEqual(@as(usize, 1), term.screenRow());

    term.resizeRows(Term.rows);
    try r.resize(Term.cols, Term.rows, 1);
    var grown: TestWriter = .{};
    grown.init();
    try r.render(&grown.w);
    term.feed(grown.bytes());
    try answerQuery(&r, &term);
    // Same screen line, same cursor row, and rows below that are the new
    // empty ones: a pull would have moved the band off its line.
    try testing.expectEqualStrings("", term.screenText(0));
    try testing.expectEqualStrings(popup_rows[0], term.screenText(1));
    try testing.expectEqual(@as(usize, 1), term.screenRow());
    for (2..Term.rows) |y| try testing.expectEqualStrings("", term.screenText(y));
    try testing.expectEqual(@as(u16, 1), r.painted_rows);
    // Nothing was erased and nothing was reclaimed: the committed rows
    // are still in the terminal's buffer, and the three rows the band
    // gave up are still the region's own and still out of reach.
    try testing.expect(!r.retireDue());
    for (0..history) |y| {
        try testing.expectEqual(@as(usize, 1), rowsHolding(&term, transcriptRow(y)));
    }

    // Dragged down to one row and out to full height again: now the
    // cursor IS on the window's last row, so the growth pulls the
    // scrollback back and the retired rows come onto the screen — where
    // the region takes them back, and leaves the committed transcript,
    // the live band and its line alone.
    term.resizeRows(1);
    try r.resize(Term.cols, 1, 1);
    var one_row: TestWriter = .{};
    one_row.init();
    try r.render(&one_row.w);
    term.feed(one_row.bytes());
    try answerQuery(&r, &term);
    term.resizeRows(Term.rows);
    try r.resize(Term.cols, Term.rows, 1);
    var pulled: TestWriter = .{};
    pulled.init();
    try r.render(&pulled.w);
    term.feed(pulled.bytes());
    // The pull retired the reach, so the frame that reveals the rows the
    // clip left above the band could not walk up to them; its own reply
    // measures them and the next frame takes exactly those back.
    try answerQuery(&r, &term);
    var reclaimed: TestWriter = .{};
    reclaimed.init();
    try r.render(&reclaimed.w);
    term.feed(reclaimed.bytes());

    // Where the live band ended up. The pull handed back every row the
    // one-row window held above it: the `history` committed rows, the
    // three popup rows the clip left above the band, and the one row
    // that clip erased in place — ten rows above a band that keeps its
    // own line.
    const band_line = history + 3 + 1;
    try testing.expectEqual(@as(usize, 0), restoredBandRows(&term, band_line, &popup_rows));
    try testing.expectEqualStrings(popup_rows[0], term.screenText(band_line));
    try testing.expectEqualStrings("", term.screenText(band_line - 1));
    for (band_line + 1..Term.rows) |y| try testing.expectEqualStrings("", term.screenText(y));
    try testing.expectEqual(@as(usize, band_line), term.screenRow());
    try testing.expect(!r.retireDue());
    for (0..history) |y| {
        try testing.expectEqual(@as(usize, 1), rowsHolding(&term, transcriptRow(y)));
    }
}

test "region: a shrink that only drops the blank tail keeps the cursor's line" {
    // The growth that must NOT pull, twice. The popup is clipped into a
    // three-row window and dismissed to one row, which parks the cursor
    // a row above the window's last one; the window then grows to its
    // full height and the new rows are added BELOW the cursor, so
    // nothing above the band top becomes visible. Dragged shorter after
    // that, the window gives up the blank tail it had below the cursor
    // and nothing else — the cursor's own line still fits, so it stays
    // exactly where it is, and the rows above the band do not move
    // either way.
    //
    // Reading either step as "the cursor ends on the last row" would
    // credit the restore as a pull: the erase would walk into rows the
    // screen is not showing, clamp on the window's first row and blank
    // committed text, and the next frame's relative moves would start
    // from the wrong line entirely.
    const history = 6; // committed rows above the band when it opens
    var r = try makeRegion(@intCast(popup_rows.len), .{});
    defer r.deinit();
    try drawPopup(&r.cur, @intCast(popup_rows.len));
    var term: Term = .{};
    feedTranscript(&term, history);
    var open: TestWriter = .{};
    open.init();
    try r.render(&open.w);
    term.feed(open.bytes());

    // A physical clip to three rows re-bases the band onto two.
    term.resizeRows(3);
    try r.resize(Term.cols, 3, 2);
    try drawPopup(&r.cur, 2);
    var clipped: TestWriter = .{};
    clipped.init();
    try r.render(&clipped.w);
    term.feed(clipped.bytes());
    try testing.expectEqualStrings("", term.screenText(0));
    for (0..2) |y| try testing.expectEqualStrings(popup_rows[y], term.screenText(1 + y));
    try testing.expectEqual(@as(usize, 2), term.screenRow());

    // Dismissed to one row: the cursor is parked a row above the
    // window's last one, with a blank tail under it, and the rows the
    // clip gave up are still tracked above the band.
    try r.setHeight(1);
    var dismissed: TestWriter = .{};
    dismissed.init();
    try r.render(&dismissed.w);
    term.feed(dismissed.bytes());
    try testing.expectEqualStrings(popup_rows[0], term.screenText(1));
    try testing.expectEqualStrings("", term.screenText(2));
    try testing.expectEqual(@as(usize, 1), term.screenRow());
    // The three rows the band gave up are out of reach on this window, so
    // no erase is owed and nothing above them is touched.
    try testing.expect(!r.retireDue());

    // Full height: the rows are added below the cursor, so the band
    // keeps its line and nothing above it becomes visible.
    term.resizeRows(Term.rows);
    try r.resize(Term.cols, Term.rows, 1);
    var grown: TestWriter = .{};
    grown.init();
    try r.render(&grown.w);
    term.feed(grown.bytes());
    try testing.expectEqualStrings("", term.screenText(0));
    try testing.expectEqualStrings(popup_rows[0], term.screenText(1));
    try testing.expectEqual(@as(usize, 1), term.screenRow());
    for (2..Term.rows) |y| try testing.expectEqualStrings("", term.screenText(y));
    try testing.expect(!r.retireDue());

    // Down to five rows — still taller than the cursor's line, so the
    // window gives up the blank tail and the cursor keeps screen row 1.
    term.resizeRows(5);
    try r.resize(Term.cols, 5, 1);
    var five: TestWriter = .{};
    five.init();
    try r.render(&five.w);
    term.feed(five.bytes());
    try testing.expectEqualStrings("", term.screenText(0));
    try testing.expectEqualStrings(popup_rows[0], term.screenText(1));
    try testing.expectEqual(@as(usize, 1), term.screenRow());
    for (2..5) |y| try testing.expectEqualStrings("", term.screenText(y));
    try testing.expectEqual(@as(u16, 1), r.painted_rows);

    // And out to full height again: still a downward growth, because the
    // cursor is not on the window's last row. The next keystroke belongs
    // to the live band and lands on the line the band kept; the retired
    // run is still the region's own, nothing above the band was erased,
    // and every committed row is still in the terminal's buffer once.
    term.resizeRows(Term.rows);
    try r.resize(Term.cols, Term.rows, 1);
    try drawRow(&r.cur, 0, "skript> de");
    var edit: TestWriter = .{};
    edit.init();
    try r.render(&edit.w);
    term.feed(edit.bytes());
    try testing.expectEqualStrings("skript> de", term.screenText(1));
    try testing.expectEqualStrings("", term.screenText(0));
    for (2..Term.rows) |y| try testing.expectEqualStrings("", term.screenText(y));
    try testing.expectEqual(@as(usize, 1), term.screenRow());
    try testing.expectEqual(@as(u16, 1), r.painted_rows);
    try testing.expect(!r.retireDue());
    for (0..history) |y| {
        try testing.expectEqual(@as(usize, 1), rowsHolding(&term, transcriptRow(y)));
    }
}

test "region: multi-row text output moves the retirement past what it wrote" {
    // The same shrink-and-restore run with a `.text` append in it. The
    // paint envelope turns DECAWM off for the whole frame and every `\n`
    // in a `.text` is written as `\r\n`, so a two-line text is two HARD
    // row moves: the band top drops past them by exactly that count, and
    // the run of retired rows above it has to move down with it.
    //
    // Leaving those offsets where they were points the erase at the
    // committed gap the text just opened — it blanks the two rows the
    // caller wrote — and leaves the two rows the band gave up on screen
    // as residue. The rows either side of the gap are what tells the
    // two apart: the band re-claims its own and nothing else.
    const committed = Term.rows - popup_rows.len; // transcript above the band
    var r = try makeRegion(@intCast(popup_rows.len), .{});
    defer r.deinit();
    try drawPopup(&r.cur, @intCast(popup_rows.len));
    var term: Term = .{};
    feedTranscript(&term, committed);
    var open: TestWriter = .{};
    open.init();
    try r.render(&open.w);
    term.feed(open.bytes());
    try answerQuery(&r, &term);

    for ([_]u16{ 3, 2, 1 }) |rows| {
        term.resizeRows(rows);
        try r.resize(Term.cols, rows, rows);
        try drawPopup(&r.cur, rows);
        var shorter: TestWriter = .{};
        shorter.init();
        try r.render(&shorter.w);
        term.feed(shorter.bytes());
        try answerQuery(&r, &term);
    }
    // Five of the band's own rows are retired above a one-row band, and
    // this window reaches none of them.
    try testing.expect(!r.retireDue());

    // The app prints two lines while the one-row window holds them: both
    // land in the scrollback above the band, and the retired run moves
    // down past them rather than staying on top of them.
    try r.append(.{ .text = "late-a\nlate-b" });
    var flushed: TestWriter = .{};
    flushed.init();
    try r.render(&flushed.w);
    term.feed(flushed.bytes());
    try answerQuery(&r, &term);
    try testing.expectEqualStrings(popup_rows[0], term.screenText(0));
    // Still out of reach below the two rows just written.
    try testing.expect(!r.retireDue());

    // The window opens back to the popup's six rows and then to its full
    // height. Three of the five retired rows are on screen with the band
    // now, so this frame takes those back and leaves the two written
    // rows between them and the live band exactly where they are.
    term.resizeRows(popup_rows.len);
    try r.resize(Term.cols, popup_rows.len, @intCast(popup_rows.len));
    try drawPopup(&r.cur, @intCast(popup_rows.len));
    var wide: TestWriter = .{};
    wide.init();
    try r.render(&wide.w);
    term.feed(wide.bytes());
    // The growth retired the reach, so this frame reserves and repaints
    // without erasing: the retired rows are tracked above the band and
    // are still the band's own.
    try answerQuery(&r, &term);
    try testing.expect(!r.retireDue());

    term.resizeRows(Term.rows);
    try r.resize(Term.cols, Term.rows, @intCast(popup_rows.len));
    var restored: TestWriter = .{};
    restored.init();
    try r.render(&restored.w);
    term.feed(restored.bytes());
    // The restore retires the reach, so this frame cannot walk up to the
    // rows it gave up; its reply measures them and the next frame takes
    // exactly those back, leaving the two rows the text wrote alone.
    try answerQuery(&r, &term);
    var reclaimed: TestWriter = .{};
    reclaimed.init();
    try r.render(&reclaimed.w);
    term.feed(reclaimed.bytes());

    // Where the live band ended up. The pull to six rows handed 5 rows
    // of scrollback to the screen, the reservation that followed pushed
    // those 5 rows back off, and the growth to full height handed 18
    // more — far enough to reach every transcript row this run wrote.
    // The band itself never moved, so it is on screen row 18 with the
    // two rows the text wrote on 16 and 17, and the two retired rows
    // that were out of reach on 12 and 13.
    const band_top = 18;
    const late_rows = [_][]const u8{ "late-a", "late-b" };
    for (popup_rows, 0..) |row, y| {
        try testing.expectEqualStrings(row, term.screenText(band_top + y));
    }
    for (late_rows, 0..) |row, y| {
        try testing.expectEqualStrings(row, term.screenText(band_top - 2 + y));
    }
    try testing.expectEqual(@as(usize, Term.rows - 1), term.screenRow());
    // No band row of its own survives above it, and nothing the text
    // wrote was taken with them: every committed row — the transcript's
    // own and these two — is still in the terminal's buffer exactly once.
    try testing.expectEqual(@as(usize, 0), restoredBandRows(&term, band_top, &popup_rows));
    try testing.expect(!r.retireDue());
    for (0..committed) |y| {
        try testing.expectEqual(@as(usize, 1), rowsHolding(&term, transcriptRow(y)));
    }
    for (late_rows) |row| try testing.expectEqual(@as(usize, 1), rowsHolding(&term, row));
}

test "region: a retirement erase the queue cannot hold stays owed whole" {
    // The erase belongs to a transactional frame like any other byte
    // sequence: it has to reach the terminal exactly once. A queue too
    // small to hold it discards the frame whole, so the retired rows stay
    // the band's own — still tracked, still owed — and the retry takes
    // them back once instead of dropping them (residue on screen) or
    // erasing over rows it never owned.
    var r = try makeRegion(@intCast(popup_rows.len), .{});
    defer r.deinit();
    try drawPopup(&r.cur, @intCast(popup_rows.len));
    var term: Term = .{};
    feedHistory(&term);
    var open: TestWriter = .{};
    open.init();
    try r.render(&open.w);
    term.feed(open.bytes());
    try answerQuery(&r, &term);

    // A physical clip into a two-row window retires four of the band's
    // rows; a full-height window pulls them back onto the screen.
    term.resizeRows(2);
    try r.resize(Term.cols, 2, 2);
    try drawPopup(&r.cur, 2);
    var clipped: TestWriter = .{};
    clipped.init();
    try r.render(&clipped.w);
    term.feed(clipped.bytes());
    try answerQuery(&r, &term);
    term.resizeRows(Term.rows);
    try r.resize(Term.cols, Term.rows, @intCast(popup_rows.len));
    try drawPopup(&r.cur, @intCast(popup_rows.len));
    var grown: TestWriter = .{};
    grown.init();
    try r.render(&grown.w);
    term.feed(grown.bytes());
    // The growth retired the reach, so this frame reserved and repainted
    // without erasing: the rows the clip left are on the screen again and
    // are still the band's own. The reply that lands next measures how far
    // up they are, and only then is the erase owed.
    try answerQuery(&r, &term);
    try testing.expect(r.retireDue());

    var q = try output.OutputQueue.init(testing.allocator, .{ .capacity = 32, .watermark = 16 });
    defer q.deinit();
    q.beginFrame();
    try testing.expectError(error.WriteFailed, r.render(q.writer()));
    try testing.expect(q.frameOverflowed());
    q.abortFrame();
    // Nothing reached the terminal, and the ownership is exactly what it
    // was: the retired rows are still the band's, still owed, and the
    // committed transcript above them is untouched.
    try testing.expectEqual(@as(usize, 0), q.pending());
    try testing.expectEqual(@as(u16, popup_rows.len), r.painted_rows);
    try testing.expect(r.retireDue());
    for (history_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.text(y));

    // The retry owns the erase: the retired rows are blanked exactly once
    // and the band keeps the rows it already painted.
    var retry: TestWriter = .{};
    retry.init();
    try r.render(&retry.w);
    term.feed(retry.bytes());
    try testing.expect(!r.retireDue());
    // The live band ends on the row the cursor is parked on, and nothing
    // it wrote and gave up is left above it.
    const band_line = term.screenRow() -| (popup_rows.len - 1);
    try testing.expectEqual(@as(usize, 0), restoredBandRows(&term, band_line, &popup_rows));
    for (popup_rows, 0..) |row, y| {
        try testing.expectEqualStrings(row, term.screenText(band_line + y));
    }
    for (history_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.text(y));
    try testing.expectEqual(@as(u16, popup_rows.len), r.painted_rows);
}

test "region: repeated growth and shrink frames keep one band and its history" {
    // Every transition moves the band by exactly the rows it gained or
    // lost: one stale reservation or erase per cycle accumulates, and
    // the band's own rows are what every later diff paints into. A grow
    // and a shrink inside ONE frame settle on the extent already on
    // screen, so that frame is byte-empty.
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try tagRows(&r.cur, 2, 'a');
    var term: Term = .{};
    feedHistory(&term);
    var t0: TestWriter = .{};
    t0.init();
    try r.render(&t0.w);
    term.feed(t0.bytes());

    for (0..3) |_| {
        try r.setHeight(6);
        var grow: TestWriter = .{};
        grow.init();
        try r.render(&grow.w);
        term.feed(grow.bytes());
        // Four rows added, nothing else: rows 7..10 are new band rows,
        // the two painted ones did not move.
        try testing.expectEqual(@as(usize, 10), term.row);
        try testing.expectEqual(@as(u16, 6), r.painted_rows);
        for (0..2) |y| try expectLabel(&term, 5 + y, 'a', y);

        try r.setHeight(2);
        var shrink: TestWriter = .{};
        shrink.init();
        try r.render(&shrink.w);
        term.feed(shrink.bytes());
        // Four row-scoped erases and the park back on the band bottom.
        try testing.expectEqual(@as(usize, 4), count(shrink.bytes(), "\x1b[K"));
        try testing.expectEqual(@as(usize, 6), term.row);
        try testing.expectEqual(@as(u16, 2), r.painted_rows);

        try r.setHeight(6);
        try r.setHeight(2);
        var idle: TestWriter = .{};
        idle.init();
        try r.render(&idle.w);
        try testing.expectEqualStrings("", idle.bytes());
        try testing.expectEqual(@as(usize, 6), term.row);
    }

    // Three cycles later the grid is exactly what it started as: the
    // transcript, the two painted band rows, and nothing below them.
    for (history_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.text(y));
    for (0..2) |y| try expectLabel(&term, 5 + y, 'a', y);
    for (0..8) |y| try testing.expectEqualStrings("", term.text(7 + y));
    try testing.expectEqual(@as(usize, 6), term.row);
}

test "region: a collapse inside a coalesced height keeps the band in place" {
    // Height 0 followed by the original height inside one tick released
    // nothing: no collapse frame ran, so no rows settled and nothing may
    // be reserved from the cursor. Re-reserving here would paint a
    // second copy of the band below the first and freeze the original
    // rows above it.
    var r = try makeRegion(4, .{});
    defer r.deinit();
    try tagRows(&r.cur, 4, 'a');
    var term: Term = .{};
    feedHistory(&term);
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());
    try testing.expectEqual(@as(usize, 8), term.row);

    try r.setHeight(0);
    try r.setHeight(4);
    // Height 0 empties the drawing buffer, and the reshape back up
    // cannot invent the rows it lost: the app lays the band out again,
    // exactly as a real frame does after a height change.
    try tagRows(&r.cur, 4, 'a');
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    term.feed(t2.bytes());
    try testing.expectEqualStrings("", t2.bytes());
    try testing.expectEqual(@as(usize, 8), term.row);
    try testing.expectEqual(@as(u16, 4), r.painted_rows);
    for (history_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.text(y));
    for (0..4) |y| try expectLabel(&term, 5 + y, 'a', y);
    // The band bottom is still the last row it owns: a frame painting
    // from anywhere else lands below the band.
    try testing.expectEqualStrings("", term.text(9));
}

test "region: a real collapse settles the band, a reopen reserves below it" {
    // The collapse frame that DID run: the rows stay on screen as
    // settled content (nothing above the band is erased), and the band
    // that comes back is reserved below them, so the settled text stays
    // readable and the band owns only what it painted.
    var r = try makeRegion(3, .{});
    defer r.deinit();
    try tagRows(&r.cur, 3, 'a');
    var term: Term = .{};
    feedHistory(&term);
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());
    try testing.expectEqual(@as(usize, 7), term.row);

    try r.setHeight(0);
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    term.feed(t2.bytes());
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "\x1b[K"));
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "\x1b[J"));
    for (history_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.text(y));
    for (0..3) |y| try expectLabel(&term, 5 + y, 'a', y);
    try testing.expectEqual(@as(usize, 7), term.row);
    try testing.expectEqual(@as(u16, 0), r.painted_rows);

    // A released band is silent until it is re-created.
    var idle: TestWriter = .{};
    idle.init();
    try r.render(&idle.w);
    try testing.expectEqualStrings("", idle.bytes());

    try r.setHeight(2);
    try tagRows(&r.cur, 2, 'b');
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    term.feed(t3.bytes());
    try testing.expectEqual(@as(usize, 0), count(t3.bytes(), "\x1b[J"));
    for (history_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.text(y));
    for (0..3) |y| try expectLabel(&term, 5 + y, 'a', y);
    for (0..2) |y| try expectLabel(&term, 8 + y, 'b', y);
    try testing.expectEqual(@as(usize, 9), term.row);
    try testing.expectEqual(@as(u16, 2), r.painted_rows);
}

test "region: a ledger flush settles a pending height change" {
    // A queued scrollback row and a taller band in the SAME tick: the
    // flush erases the band from the anchor and repaints every row at
    // the new height, so the band IS the new size once that frame lands.
    // Leaving the height change pending would reserve the rows a second
    // time: the band would sit two rows lower than the rows it owns and
    // every later diff would paint that far below its own top.
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try tagRows(&r.cur, 2, 'a');
    var term: Term = .{};
    feedHistory(&term);
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());
    try testing.expectEqual(@as(usize, 6), term.row);

    try r.setHeight(4);
    try r.append(.{ .line = "hist-new" });
    try tagRows(&r.cur, 4, 'b');
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    term.feed(t2.bytes());
    // The queued row lands ABOVE the band, the band moved down exactly
    // one row, and its four rows are the ones painted.
    try testing.expectEqualStrings("hist-new", term.text(5));
    for (history_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.text(y));
    for (0..4) |y| try expectLabel(&term, 6 + y, 'b', y);
    try testing.expectEqual(@as(usize, 9), term.row);
    try testing.expectEqual(@as(u16, 4), r.painted_rows);

    // The height change is settled: the next frame has nothing to say.
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    term.feed(t3.bytes());
    try testing.expectEqualStrings("", t3.bytes());
    try testing.expectEqual(@as(usize, 9), term.row);

    // And a real change still lands on the band's own top row.
    try clearRow(&r.cur, 0, 2);
    try drawRow(&r.cur, 0, "ZZ");
    var t4: TestWriter = .{};
    t4.init();
    try r.render(&t4.w);
    term.feed(t4.bytes());
    try testing.expectEqualStrings("ZZ", term.text(6));
    try testing.expectEqualStrings("b1", term.text(7));
    try testing.expectEqual(@as(usize, 9), term.row);
}

test "region: a height frame the queue cannot hold keeps one band for the retry" {
    // A height change is a PHYSICAL move, so its reservation has to
    // reach the terminal exactly once. The output queue stages a frame
    // atomically: a frame it cannot hold is discarded whole, the region
    // still owes the change, and the retry must leave one band — one
    // reservation, one set of rows, the transcript above untouched —
    // rather than reserving on top of a move that never happened.
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try tagRows(&r.cur, 2, 'a');
    var term: Term = .{};
    feedHistory(&term);
    var t0: TestWriter = .{};
    t0.init();
    try r.render(&t0.w);
    term.feed(t0.bytes());
    try testing.expectEqual(@as(usize, 6), term.row);

    try r.setHeight(4);
    try tagRows(&r.cur, 4, 'b');
    // Room for the envelope, the two-row reservation and the band-top
    // move, then not one row of the repaint: the reservation IS staged
    // and the whole frame is still discarded.
    var q = try output.OutputQueue.init(testing.allocator, .{ .capacity = 30, .watermark = 20 });
    defer q.deinit();
    q.beginFrame();
    try testing.expectError(error.WriteFailed, r.render(q.writer()));
    try testing.expect(q.frameOverflowed());
    q.abortFrame();
    // Nothing reached the terminal and the change is still owed whole.
    try testing.expectEqual(@as(usize, 0), q.pending());
    try testing.expectEqual(@as(u16, 4), r.height);
    try testing.expectEqual(@as(u16, 2), r.painted_rows);
    try testing.expect(r.height_dirty);
    try testing.expectEqual(@as(usize, 6), term.row);

    // The retry owns the band: two rows reserved, four painted rows,
    // the cursor on the new band bottom.
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());
    for (history_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.text(y));
    for (0..4) |y| try expectLabel(&term, 5 + y, 'b', y);
    try testing.expectEqual(@as(usize, 8), term.row);
    try testing.expectEqual(@as(u16, 4), r.painted_rows);
    try testing.expect(!r.height_dirty);

    // And nothing is owed after that: the reservation is not replayed.
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try testing.expectEqualStrings("", t2.bytes());
    try testing.expectEqual(@as(usize, 8), term.row);
}

test "region: a taller band whose rows went blank cleans its tail row-scoped" {
    // The app emptied the band and grew it in one tick. The two new
    // rows are reserved, the rows the frame no longer paints are erased
    // with a row-scoped EL, and the boundary is the band top: the
    // transcript above keeps every row.
    var r = try makeRegion(3, .{});
    defer r.deinit();
    try tagRows(&r.cur, 3, 'a');
    var term: Term = .{};
    feedHistory(&term);
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());
    try testing.expectEqual(@as(usize, 7), term.row);

    try r.setHeight(5);
    r.cur.clear(); // nothing drawn at all
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    term.feed(t2.bytes());
    for (history_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.text(y));
    for (0..5) |y| try testing.expectEqualStrings("", term.text(5 + y));
    try testing.expectEqual(@as(usize, 9), term.row);
    try testing.expectEqual(@as(u16, 5), r.painted_rows);
    // The band owns nothing now, so the next frame knows it must not
    // treat the whole extent as painted.
    try testing.expectEqual(@as(u16, 0), r.high_water);
    // Row-scoped: no ED0, so nothing above the band is ever erased.
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "\x1b[J"));

    // Content again lands on the band's own rows, from its own top.
    try tagRows(&r.cur, 5, 'c');
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    term.feed(t3.bytes());
    for (history_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.text(y));
    for (0..5) |y| try expectLabel(&term, 5 + y, 'c', y);
    try testing.expectEqual(@as(usize, 9), term.row);
}

test "region: height zero collapses the band without erasing anything" {
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    var term: Term = .{};
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());

    try r.setHeight(0);
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    term.feed(t2.bytes());
    // Release only: the cursor parks, nothing is erased (the rows stay
    // on screen as settled content).
    try testing.expectEqualStrings(framed("\r"), t2.bytes());
    try testing.expectEqual(@as(u16, 0), r.painted_rows);
    try testing.expectEqualStrings("ab", term.text(0));
    try testing.expectEqualStrings("cd", term.text(1));

    // A collapsed band is silent until it grows again.
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    try testing.expectEqualStrings("", t3.bytes());

    // Growing back re-reserves from the cursor and appends the rows: the
    // settled rows above keep their text, and the band owns the two rows
    // it wrote, ending on the row the cursor parks on.
    try r.setHeight(2);
    try drawRow(&r.cur, 0, "zz");
    try drawRow(&r.cur, 1, "yy");
    var t4: TestWriter = .{};
    t4.init();
    try r.render(&t4.w);
    term.feed(t4.bytes());
    try testing.expectEqualStrings("ab", term.text(0));
    try testing.expectEqualStrings("cd", term.text(1));
    const band = term.row -| 1; // the parked cursor IS the band bottom
    try testing.expectEqualStrings("zz", term.text(band));
    try testing.expectEqualStrings("yy", term.text(band + 1));
    try testing.expectEqual(@as(usize, 0), term.col);
    try testing.expectEqual(@as(u16, 2), r.painted_rows);
}

test "region: a released band settles the row it parks on and a queued row lands below it" {
    // The release hands the whole band to the ledger, the cursor's OWN
    // row included: it is transcript from that moment, and it keeps the
    // geometry it was painted with so a later column change can repack
    // it like any other non-cursor group. That is what makes the row
    // BELOW it the first one a frame may write on — a queued row that
    // started on it would overwrite committed content and give the
    // ledger two rows for one physical row, and every offset above the
    // band would then be a row group out.
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    var term: Term = .{};
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());
    try r.setHeight(0);
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    term.feed(t2.bytes());
    try testing.expectEqual(@as(usize, 1), term.row);

    // The app prints while the band is gone. The row the cursor parks on
    // keeps the text the band left there, and the queued row is the one
    // below it — never over the top of it.
    try r.append(.{ .line = "late" });
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    term.feed(t3.bytes());
    try testing.expectEqualStrings("ab", term.text(0));
    try testing.expectEqualStrings("cd", term.text(1));
    try testing.expectEqualStrings("late", term.text(2));
    try testing.expectEqual(@as(usize, 3), term.row);

    // And a band re-created after all that starts below the queued row,
    // with the settled rows still exactly where they were.
    try r.setHeight(2);
    try drawRow(&r.cur, 0, "zz");
    try drawRow(&r.cur, 1, "yy");
    var t4: TestWriter = .{};
    t4.init();
    try r.render(&t4.w);
    term.feed(t4.bytes());
    try testing.expectEqualStrings("ab", term.text(0));
    try testing.expectEqualStrings("cd", term.text(1));
    try testing.expectEqualStrings("late", term.text(2));
    try testing.expectEqualStrings("zz", term.text(4));
    try testing.expectEqualStrings("yy", term.text(5));
    try testing.expectEqual(@as(usize, 5), term.row);
    try testing.expectEqual(@as(u16, 2), r.painted_rows);
}

test "region: no strategy emits ED2 or ED3, and ED0 only from the band anchor" {
    // The tmux/conhost matrix: drive every strategy in EVERY resize
    // mode, then audit the bytes. ED2 (`ESC[2J`) and ED3 (`ESC[3J`)
    // must never appear: they would destroy scrollback above the band.
    // ED0 may only appear where the cursor has just been moved to the
    // band top — the ledger flush always, and the `.append` resize.
    const Capture = struct {
        fn add(list: *std.ArrayList(u8), t: *const TestWriter) !void {
            try list.appendSlice(testing.allocator, t.bytes());
        }
    };
    for ([_]ResizeMode{ .append, .rebuild, .preserve }) |mode| {
        var r = try makeRegion(3, .{ .append_lines = true, .mode = mode });
        defer r.deinit();
        try fillBand(&r.cur, "abc");

        var all: std.ArrayList(u8) = .empty;
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
        try Capture.add(&all, &t); // height up

        try r.setHeight(2);
        t.init();
        try r.render(&t.w);
        try Capture.add(&all, &t); // height down

        try r.resize(40, Term.rows, 2);
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
        while (std.mem.findPos(u8, bytes, at, "\x1b[J")) |erase| {
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

// ── C1: the ledger ───────────────────────────────

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
    try testing.expectEqual(@as(usize, 1), (try r.historyPending()).len);
    try testing.expectEqual(@as(u64, 7), (try r.historyPending())[0]);
    try testing.expect(r.historyRetained(7));

    // The transport drained: acknowledge once, receipts released.
    const receipts = r.acknowledgeDrained();
    try testing.expectEqual(@as(usize, 1), receipts.len);
    try testing.expectEqual(@as(u64, 7), receipts[0]);
    try testing.expect(!r.historyRetained(7));
    try testing.expectEqual(@as(usize, 0), (try r.historyPending()).len);
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
        sync_on ++ hide_c ++ aw_on ++ "fresh\r\n\ra\r" ++ cpr_q ++ sync_off,
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
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4 }, try r.historyPending());

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
    try testing.expectEqualSlices(u64, &.{ 1, 3 }, try r.historyPending());
    try testing.expectEqual(@as(usize, 0), r.append_queue.items.len);
    // One drain acknowledges exactly the written batches: the settled
    // one from the earlier frame and the replay.
    try testing.expectEqualSlices(u64, &.{ 1, 3 }, r.acknowledgeDrained());
    try testing.expectEqual(@as(usize, 0), (try r.historyPending()).len);
    try testing.expectEqual(@as(usize, 0), r.historyBytes());
}

test "region: a piped replay supersedes the queued appends" {
    // A pipe is the same contract without a cursor: the replay alone
    // reaches the stream.
    var r = try makeRegion(1, .{ .interactive = false });
    defer r.deinit();
    try r.resize(4, Term.rows, 1);
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

    const prologue = sync_on.len + hide_c.len + aw_on.len;
    var q = try output.OutputQueue.init(testing.allocator, .{
        .capacity = prologue + "rows\r\n".len - 1,
        .watermark = prologue,
    });
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

// ── C2: resize modes ──────────────────────────────

test "region: resize append clears from the anchor and repaints in place" {
    var r = try makeRegion(3, .{ .mode = .append });
    defer r.deinit();
    try r.resize(10, Term.rows, 3);
    try fillBand(&r.cur, "abc");

    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    try r.resize(40, Term.rows, 3);
    try clearRow(&r.cur, 0, 40);
    try clearRow(&r.cur, 1, 40);
    try clearRow(&r.cur, 2, 40);
    try fillBand(&r.cur, "abc");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    var term: Term = .{};
    term.feed(t1.bytes());
    term.feed(t2.bytes());
    // The band stayed exactly where it was: it repainted on its own rows,
    // with no reservation and no push, and nothing above it moved.
    for (0..3) |y| try testing.expectEqualStrings("abc", term.text(y));
    try testing.expectEqual(@as(usize, 2), term.row);
    try testing.expect(!r.width_dirty);
    // `.append` clears the band from its own top, and never the screen.
    try testing.expectEqual(@as(usize, 1), count(t2.bytes(), "\x1b[J"));
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "\x1b[2J"));
}

test "region: resize rebuild repaints downward and leaves the old extent painted" {
    var r = try makeRegion(3, .{ .mode = .rebuild });
    defer r.deinit();
    try r.resize(10, Term.rows, 3);
    try fillBand(&r.cur, "abc");

    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    try r.resize(40, Term.rows, 3);
    try clearRow(&r.cur, 0, 40);
    try clearRow(&r.cur, 1, 40);
    try clearRow(&r.cur, 2, 40);
    try fillBand(&r.cur, "xyz");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    var term: Term = .{};
    term.feed(t1.bytes());
    term.feed(t2.bytes());
    // The re-anchor repaints the band on the OLD bottom row and walks
    // down from there, so the rows it gave up keep the content they had.
    try testing.expectEqualStrings("abc", term.text(0));
    try testing.expectEqualStrings("abc", term.text(1));
    for (0..3) |y| try testing.expectEqualStrings("xyz", term.text(2 + y));
    try testing.expectEqual(@as(usize, 4), term.row);
    // No ED0: the rows above the band are never touched.
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "\x1b[J"));
}

test "region: resize rebuild on a shorter band leaves the extra rows settled" {
    var r = try makeRegion(3, .{ .mode = .rebuild });
    defer r.deinit();
    try r.resize(10, Term.rows, 3);
    try fillBand(&r.cur, "abc");
    var term: Term = .{};
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());
    // The first frame's own query is answered before the geometry moves,
    // so the slot is free for the re-anchor the resize owes.
    try answerQuery(&r, &term);

    // A width change together with a shorter band: `.rebuild` re-anchors
    // at the live bottom and repaints downward. The band top moves to
    // the old bottom (row 2), so the band now owns rows 2 and 3 and
    // rows 0 and 1 stay on screen as settled content.
    try r.resize(20, Term.rows, 2);
    try clearRow(&r.cur, 0, 20);
    try clearRow(&r.cur, 1, 20);
    try drawRow(&r.cur, 0, "one");
    try drawRow(&r.cur, 1, "two");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    // The band top moved down to the old bottom; the anchor follows the
    // cursor this frame's own walk produced, and the CPR reply confirms
    // it below.
    try testing.expectEqual(@as(u16, 2), r.painted_rows);
    term.feed(t2.bytes());
    try testing.expectEqualStrings("one", term.text(2));
    try testing.expectEqualStrings("two", term.text(3));
    // The rows the shorter band released stay exactly as they were: a
    // rebuild settles the old prefix as history rather than erasing it.
    try testing.expectEqualStrings("abc", term.text(0));
    try testing.expectEqualStrings("abc", term.text(1));
    // The cursor parked on the new band bottom — the row the next
    // frame's relative moves start from.
    try testing.expectEqual(@as(usize, 3), term.row);
    // The re-anchor asks in this very frame, and a real terminal answers
    // from the parked cursor (1-indexed): the reply re-anchors exactly
    // onto the new band top.
    try testing.expectEqual(@as(usize, 1), count(t2.bytes(), cpr_q));
    try answerQuery(&r, &term);
    try testing.expectEqual(@as(u16, 3), r.anchorRow());
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
    try r.resize(10, Term.rows, 3);
    try fillBand(&r.cur, "abc");
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    // The app re-lays out settled rows for the new width: only row 1
    // changes, and it is erased and repainted at its own band row.
    try r.resize(40, Term.rows, 3);
    try clearRow(&r.cur, 1, 40);
    try drawRow(&r.cur, 1, "reflowed");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    var term: Term = .{};
    term.feed(t1.bytes());
    term.feed(t2.bytes());
    // Row-scoped: each band row is erased and repainted at its own row,
    // so the band stays exactly where it was and the rows the app did
    // not re-lay out keep their own text.
    try testing.expectEqualStrings("abc", term.text(0));
    try testing.expectEqualStrings("reflowed", term.text(1));
    try testing.expectEqualStrings("abc", term.text(2));
    try testing.expectEqual(@as(usize, 2), term.row);
    // And nothing above the band top is ever cleared.
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "\x1b[J"));
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "\x1b[2J"));
}

test "region: a preserve reflow that carries a height change erases the net tail" {
    // `.preserve` paints row-scoped, so a height change arriving WITH
    // the width change has to settle the physical extent itself: the
    // released rows are erased row-scoped and the reflow paints the rows
    // the band still owns. Rows left holding the old frame are a stale
    // row under the band — the band does not own them any more, so no
    // later frame may erase them.
    var r = try makeRegion(4, .{ .mode = .preserve });
    defer r.deinit();
    try r.resize(10, Term.rows, 4);
    try tagRows(&r.cur, 4, 'a');
    var term: Term = .{};
    feedHistory(&term);
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());
    try testing.expectEqual(@as(usize, 8), term.row);
    try testing.expectEqual(@as(u16, 4), r.painted_rows);

    // The app re-lays out the settled rows for the wider terminal and
    // asks for a two-row band in the same tick.
    try r.resize(20, Term.rows, 2);
    try tagRows(&r.cur, 2, 'b');
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    term.feed(t2.bytes());
    for (history_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.text(y));
    for (0..2) |y| try expectLabel(&term, 5 + y, 'b', y);
    try testing.expectEqualStrings("", term.text(7));
    try testing.expectEqualStrings("", term.text(8));
    try testing.expectEqual(@as(usize, 6), term.row);
    try testing.expectEqual(@as(u16, 2), r.painted_rows);
    // Row-scoped all the way: `.preserve` never clears the band.
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), "\x1b[J"));
}

test "region: an append resize and a pending height settle as one band" {
    // The terminal narrowed and the app asked for a taller band in the
    // same tick. `.append` repaints the band at the new height — its ED0
    // covers the rows a shorter band releases and the repaint creates
    // the rows a taller one needs — so the resize frame settles the
    // height too. A frame after it must not reserve those rows again:
    // the band would sit a row below the rows it owns, and every later
    // diff would paint off its own top.
    var r = try makeRegion(3, .{});
    defer r.deinit();
    try r.resize(10, Term.rows, 3);
    try tagRows(&r.cur, 3, 'a');
    var term: Term = .{};
    feedHistory(&term);
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());
    try testing.expectEqual(@as(usize, 7), term.row);

    try r.resize(20, Term.rows, 3); // width only
    try r.setHeight(4); // taller band, still before the frame
    try tagRows(&r.cur, 4, 'b');
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    term.feed(t2.bytes());
    for (history_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.text(y));
    for (0..4) |y| try expectLabel(&term, 5 + y, 'b', y);
    try testing.expectEqual(@as(usize, 8), term.row);
    try testing.expectEqual(@as(u16, 4), r.painted_rows);
    try testing.expect(!r.height_dirty);

    // The next ordinary diff paints the band's own row: the band top
    // never moved, so no walk leaves it and nothing is reserved twice.
    try clearRow(&r.cur, 1, 20);
    try drawRow(&r.cur, 1, "ZZ");
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    term.feed(t3.bytes());
    for (history_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.text(y));
    try testing.expectEqualStrings("ZZ", term.text(6));
    try testing.expectEqualStrings("b2", term.text(7));
    try testing.expectEqualStrings("", term.text(9));
    try testing.expectEqual(@as(usize, 8), term.row);
    try testing.expectEqual(@as(u16, 4), r.painted_rows);
}

test "region: a mid-stream resize does not duplicate the transcript" {
    var r = try makeRegion(2, .{ .mode = .append });
    defer r.deinit();
    try r.resize(10, Term.rows, 2);
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    try r.writeHistory(.{ .id = 1, .rows = &.{"committed"}, .kind = .append });

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(testing.allocator);
    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    try stream.appendSlice(testing.allocator, t.bytes());
    _ = r.acknowledgeDrained();

    for ([_]u16{ 20, 30, 10 }) |w| {
        try r.resize(w, Term.rows, 2);
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

// ── anchor + CPR ───────────────────────────────

test "region: CPR on the first render and after a resize, never in steady state" {
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    var term: Term = .{};
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());
    try testing.expect(std.mem.indexOf(u8, t1.bytes(), cpr_q) != null);
    // The one query the session has is answered, so the slot is free:
    // nothing is owed in steady state, and the re-query a geometry
    // change owes can actually go out.
    try answerQuery(&r, &term);

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

    try r.resize(30, Term.rows, 2);
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
    var term: Term = .{};
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());
    // The first frame's query is answered, so the re-anchor below owns a
    // FREE slot and the one query it owes can go out.
    try answerQuery(&r, &term);

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
    try testing.expectEqualStrings(framed("\r" ++ cpr_q), t3.bytes());
}

test "region: a CPR reply only counts after the region's own query" {
    // Nothing was rendered, so nothing was asked: a report that arrives
    // unasked describes nothing this Region put on the screen, and
    // letting it move the anchor would place content against a row
    // nobody queried. An absolute row also needs a declared viewport to
    // be a row at all, so the app reports its winsize first.
    var r = try makeRegion(3, .{});
    defer r.deinit();
    try r.applyCpr(9, 1);
    try testing.expectEqual(@as(u16, 0), r.anchorRow());

    var term: Term = .{};
    try r.resize(Term.cols, Term.rows, 3);
    try drawRow(&r.cur, 0, "aaa");
    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    term.feed(t.bytes());
    // Unusable until the region's own query is answered.
    try testing.expectEqual(@as(u16, 0), r.anchorRow());
    // The band painted the model's first three rows and parked the cursor
    // on the last of them, so the top the anchor reports is row 1.
    try testing.expectEqualStrings("aaa", term.screenText(0));
    try answerQuery(&r, &term);
    try testing.expectEqual(@as(u16, 1), r.anchorRow());
    try testing.expect(!r.anchor_dirty);

    // The same report again — a duplicate, or a terminal answering a
    // query this Region never sent. It changes nothing.
    try r.applyCpr(1, 1);
    try testing.expectEqual(@as(u16, 1), r.anchorRow());

    // A re-anchor asks exactly once, and its answer measures the same
    // row: the anchor is not a latched number.
    try r.reanchor();
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try testing.expectEqual(@as(usize, 1), count(t2.bytes(), cpr_q));
    term.feed(t2.bytes());
    try answerQuery(&r, &term);
    try testing.expectEqual(@as(u16, 1), r.anchorRow());

    // A single-row band anchors exactly at the row its cursor parked on.
    var r1 = try makeRegion(1, .{});
    defer r1.deinit();
    var term1: Term = .{};
    try r1.resize(Term.cols, Term.rows, 1);
    try drawRow(&r1.cur, 0, "a");
    var t1: TestWriter = .{};
    t1.init();
    try r1.render(&t1.w);
    term1.feed(t1.bytes());
    try answerQuery(&r1, &term1);
    try testing.expectEqual(@as(u16, 1), r1.anchorRow());
}

test "region: a geometry change discards the reply in flight and asks once more" {
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    try testing.expectEqual(@as(usize, 1), count(t.bytes(), cpr_q));

    // The columns move while that query is in flight. Its answer names
    // rows the Region has stopped tracking, so it is discarded — and the
    // anchor is unusable until a reply under the geometry that is live
    // now arrives.
    try r.resize(30, Term.rows, 2);
    try testing.expectEqual(@as(u16, 0), r.anchorRow());
    try r.applyCpr(5, 1);
    try testing.expectEqual(@as(u16, 0), r.anchorRow());

    // The slot was held, not abandoned: the next committed frame asks
    // exactly once, and its answer measures.
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try testing.expectEqual(@as(usize, 1), count(t2.bytes(), cpr_q));
    try r.applyCpr(7, 1);
    try testing.expectEqual(@as(u16, 6), r.anchorRow());
}

test "region: a late CPR reply is transformed through the clamps, not the net distance" {
    // The reply names a row the Region never tracked, so the only exact
    // answer is the composition of the ordered moves themselves. This
    // scenario is where a net distance and that composition disagree: the
    // band grows past the window's bottom and its repaint walks back up
    // past the top, so both clamps bite and the cursor ends on the LAST
    // screen row whatever the reply said.
    var r = try makeRegion(1, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "a");
    try r.resize(10, 6, 1);
    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    try testing.expect(std.mem.indexOf(u8, t.bytes(), cpr_q) != null);
    // A band taller than the window: the reservation clamps at the
    // bottom row and the walk back up to the band top clamps at the
    // first one, so the reply's row plus the net seven rows it names
    // comes back as the window's last row. A net distance would call it
    // ten; the row alone would call it three.
    try r.setHeight(8);
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try testing.expectEqual(@as(usize, 0), count(t2.bytes(), cpr_q));
    try r.applyCpr(4, 1);
    try testing.expectEqual(@as(u16, 5), r.cursor_screen);
    try testing.expectEqual(@as(u16, 0), r.anchorRow());

    // The unclamped case is a plain composition: two rows reserved, two
    // walked back up and two painted down, so the walk's reachable window
    // never fell below the row the reply named and the answer is that row
    // plus everything the moves actually reached.
    var r2 = try makeRegion(1, .{});
    defer r2.deinit();
    try drawRow(&r2.cur, 0, "a");
    try r2.resize(10, 24, 1);
    var t3: TestWriter = .{};
    t3.init();
    try r2.render(&t3.w);
    try r2.setHeight(3);
    try drawRow(&r2.cur, 1, "b");
    try drawRow(&r2.cur, 2, "c");
    var t4: TestWriter = .{};
    t4.init();
    try r2.render(&t4.w);
    try testing.expectEqual(@as(usize, 0), count(t4.bytes(), cpr_q));
    try r2.applyCpr(1, 1);
    try testing.expectEqual(@as(u16, 2), r2.cursor_screen);
    try testing.expectEqual(@as(u16, 1), r2.anchorRow());
}

test "region: a stale reply in flight keeps the session silent" {
    // A geometry change makes the outstanding reply untrustworthy, so it
    // will be discarded — and until it lands there is nothing to ask and
    // nothing to draw. Emitting an envelope a tick anyway would do it
    // again on every tick of a slow terminal's silence.
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    var term: Term = .{};
    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    term.feed(t.bytes());
    try r.resize(30, Term.rows, 2);
    // The width change has real work of its own: it repaints the band at
    // the new width. That frame cannot ask — the stale reply still holds
    // the slot — and every frame after it is a byte-empty tick.
    var resized: TestWriter = .{};
    resized.init();
    try r.render(&resized.w);
    term.feed(resized.bytes());
    try testing.expectEqual(@as(usize, 0), count(resized.bytes(), cpr_q));
    try testing.expect(std.mem.indexOf(u8, resized.bytes(), "ab") != null);
    for (0..6) |_| {
        var idle: TestWriter = .{};
        idle.init();
        try r.render(&idle.w);
        try testing.expectEqualStrings("", idle.bytes());
    }
    // The discarded reply frees the slot, and exactly one fresh query
    // goes out on the next frame.
    try r.applyCpr(5, 1);
    try testing.expectEqual(@as(u16, 0), r.anchorRow());
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try testing.expectEqual(@as(usize, 1), count(t2.bytes(), cpr_q));
    try r.applyCpr(9, 1);
    try testing.expectEqual(@as(u16, 8), r.anchorRow());
}

test "region: an idle frame stays silent while a query waits for its reply" {
    // A terminal that answers late must not be flooded: the query went
    // out once, and nothing else goes out until the reply lands.
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    for (0..8) |_| {
        var idle: TestWriter = .{};
        idle.init();
        try r.render(&idle.w);
        try testing.expectEqualStrings("", idle.bytes());
    }
    // And once the reply lands the band is measured, so an ordinary
    // unchanged frame is still silent afterwards.
    try r.applyCpr(6, 1);
    var after: TestWriter = .{};
    after.init();
    try r.render(&after.w);
    try testing.expectEqualStrings("", after.bytes());
}

test "region: placeAt CUP's to the cell and parks at the painted band bottom" {
    var r = try makeRegion(3, .{});
    defer r.deinit();
    var term: Term = .{};
    // Absolute placement needs a declared viewport AND a measured
    // anchor: the band top is reported only once a reply under the live
    // geometry has said where the cursor parked, never from the tracked
    // shifts alone.
    try r.resize(Term.cols, Term.rows, 3);
    try drawRow(&r.cur, 0, "aaa");
    var t0: TestWriter = .{};
    t0.init();
    try r.render(&t0.w);
    term.feed(t0.bytes());
    try testing.expectEqual(@as(u16, 0), r.anchorRow());
    try answerQuery(&r, &term);
    try testing.expectEqual(@as(u16, 1), r.anchorRow());

    var t: TestWriter = .{};
    t.init();
    try r.placeAt(&t.w, 1, 2, .{ .id = 1 });
    try testing.expectEqualStrings(
        "\x1b[2;2H\x1b_Ga=p,q=1,i=1\x1b\\\x1b[3;1H",
        t.bytes(),
    );
}

test "region: graphic placement follows the band buffer row through height changes" {
    // Exact CUP/APC bytes guard the old accumulated-anchor failure, both
    // with room below the band and when CRLF growth scrolls the viewport.
    // The text model tracks buffer rows; it does not render kitty images.
    for ([_]u16{ 8, Term.rows }) |visible| {
        for ([_]bool{ false, true }) |use_resize| {
            var r = try makeRegion(2, .{});
            defer r.deinit();
            var term: Term = .{ .visible = visible };
            feedHistory(&term);
            try r.resize(Term.cols, visible, 2);
            try tagRows(&r.cur, 2, 'a');
            var t: TestWriter = .{};
            t.init();
            try r.render(&t.w);
            term.feed(t.bytes());
            try answerQuery(&r, &term);

            const opts: Region.PlaceAtOptions = .{
                .id = 42,
                .placement = 7,
                .size = .{ .width = 1, .height = 1 },
            };
            const before = "\x1b[7;2H\x1b_Ga=p,q=1,i=42,p=7,c=1,r=1\x1b\\\x1b[7;1H";
            t.init();
            try r.placeAt(&t.w, 1, 2, opts);
            try testing.expectEqualStrings(before, t.bytes());

            if (use_resize) {
                try r.resize(Term.cols, visible, 6);
            } else {
                try r.setHeight(6);
            }
            // Placement before this tick's render still uses the extent
            // actually on screen, not the new drawing-buffer height.
            t.init();
            try r.placeAt(&t.w, 1, 2, opts);
            try testing.expectEqualStrings(before, t.bytes());
            t.init();
            try r.render(&t.w);
            term.feed(t.bytes());
            try testing.expectEqual(@as(usize, 0), count(t.bytes(), "\x1b[J"));
            try testing.expectEqual(@as(usize, 0), count(t.bytes(), "\x1b[2J"));
            try testing.expectEqual(@as(usize, 0), count(t.bytes(), "\x1b[3J"));
            try testing.expectEqual(@as(usize, 10), term.row);
            const buffer_row = history_rows.len + 1;
            try expectLabel(&term, buffer_row, 'a', 1);
            const screen_row: u16 = if (visible == 8) 4 else 7;
            try testing.expectEqual(@as(usize, screen_row), buffer_row - term.top + 1);

            t.init();
            try r.placeAt(&t.w, 1, 2, opts);
            try testing.expectEqualStrings(
                if (visible == 8)
                    "\x1b[4;2H\x1b_Ga=p,q=1,i=42,p=7,c=1,r=1\x1b\\\x1b[8;1H"
                else
                    "\x1b[7;2H\x1b_Ga=p,q=1,i=42,p=7,c=1,r=1\x1b\\\x1b[11;1H",
                t.bytes(),
            );

            if (use_resize) {
                try r.resize(Term.cols, visible, 2);
            } else {
                try r.setHeight(2);
            }
            t.init();
            try r.render(&t.w);
            term.feed(t.bytes());
            try testing.expectEqual(@as(usize, 4), count(t.bytes(), "\x1b[K"));
            try testing.expectEqual(@as(usize, 0), count(t.bytes(), "\x1b[J"));
            try expectLabel(&term, buffer_row, 'a', 1);
            for (history_rows, 0..) |row, y| {
                try testing.expectEqualStrings(row, term.text(y));
            }
            t.init();
            try r.placeAt(&t.w, 1, 2, opts);
            try testing.expectEqualStrings(
                if (visible == 8)
                    "\x1b[4;2H\x1b_Ga=p,q=1,i=42,p=7,c=1,r=1\x1b\\\x1b[4;1H"
                else
                    before,
                t.bytes(),
            );
            t.init();
            try r.render(&t.w);
            try testing.expectEqualStrings("", t.bytes());
        }
    }
}

test "region: a wide glyph row diff never emits the continuation" {
    var r = try makeRegion(1, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "a👨‍🌾b");
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    try testing.expectEqualStrings(
        sync_on ++ hide_c ++ aw_on ++ "\ra👨‍🌾b\r" ++ cpr_q ++ sync_off,
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
        sync_on ++ hide_c ++ aw_on ++ "\rabc\r\n\r" ++ cpr_q ++ sync_off,
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
        return .{ .ptr = self, .vtable = &.{
            .alloc = allocFn,
            .resize = resizeFn,
            .remap = remapFn,
            .free = freeFn,
        } };
    }

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
    // A non-ASCII lead: one-byte ASCII cells are static and never copied,
    // so only a multi-byte grapheme exercises the snapshot's own storage.
    var text: [4]u8 = "äaa".*;
    var t: TestWriter = .{};

    // Warm up with REAL frames: an identical redraw early-returns, and
    // the first rendered frame only warms the arena it prepared in. Both
    // snapshot arenas (the live one and the scratch the next frame builds
    // in) and the per-cell slice list have to reach their high-water
    // mark before the steady state means anything.
    for (0..4) |i| {
        text[1] = @intCast(0xa4 + (i % 6)); // ä å æ ç è é
        t.init();
        _ = try r.cur.draw(Style{}, &text, 0, 0);
        try r.render(&t.w);
    }
    const warm = counter.allocs;
    try testing.expect(warm > 0); // the warmup really did allocate

    // Steady state with real churn: zero allocations across the whole
    // loop, measured — not inferred from an unchanged capacity.
    for (0..32) |i| {
        text[1] = @intCast(0xa4 + (i % 6));
        t.init();
        _ = try r.cur.draw(Style{}, &text, 0, 0);
        try r.render(&t.w);
    }
    try testing.expectEqual(warm, counter.allocs);
    // The snapshot OWNS the last frame's text: rewriting the app's
    // buffer in place after the commit is still real damage, so `prev`
    // never aliases the caller's bytes.
    text[1] = 0xbc; // ä -> ü in the caller's buffer, still borrowed by `cur`
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
    try testing.expectEqual(@as(usize, 0), (try r.historyPending()).len);
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

test "region: a band that owns no rows survives a startup width change and a collapse" {
    // Two states carry an empty footprint list beside a live Region: a
    // fresh `init`, which starts at the 80-column default and has
    // painted nothing, and a `.collapse` commit, which takes the extent
    // to zero. Both are reached by a column change, and the projection
    // of no rows is NO rows — crediting the cursor's exempt group to a
    // band that has none is the walk that runs off the end of the list.
    var r = try makeNativeRegion(3, .{}, 400);
    defer r.deinit();

    // A startup winsize wider than the default, before any frame ran.
    try r.resize(120, Term.rows, 3);
    try fillBand(&r.cur, "startup");
    var term: Term = .{};
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());
    try testing.expectEqual(@as(u16, 3), r.painted_rows);
    try testing.expectEqualStrings("startup", term.text(0));
    try testing.expectEqualStrings("startup", term.text(2));
    try testing.expectEqual(@as(usize, 2), term.screenRow());
    try testing.expectEqual(@as(usize, 0), term.col);

    // And the same empty extent after a release, at a narrower width.
    try r.setHeight(0);
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    term.feed(t2.bytes());
    try testing.expectEqual(@as(u16, 0), r.painted_rows);

    try r.resize(60, Term.rows, 3);
    try fillBand(&r.cur, "reopen");
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    term.feed(t3.bytes());
    try testing.expectEqual(@as(u16, 3), r.painted_rows);
    const base = term.row - 2;
    for (0..3) |y| try testing.expectEqualStrings("reopen", term.text(base + y));
    try testing.expectEqual(@as(usize, 0), term.col);
}

test "region: a band the window outgrows keeps one band and leaves no residue" {
    // 24 -> 2 -> 24 with a band the app never re-lays out: the same
    // three rows at every height, so nothing about the band shrinks
    // logically. The re-base still cannot paint three rows into a
    // two-row window, so the terminal scrolls the repaint and the band
    // comes back one row lower with the line it vacated stranded above
    // it, still holding the band's old text and owned by nobody. The
    // region has to be holding that line, because the restore hands it
    // back — and taking it back must not reach the transcript.
    const band = [_][]const u8{ "stat0", "stat1", "stat2" };
    var r = try makeRegion(3, .{});
    defer r.deinit();
    for (band, 0..) |row, y| try drawRow(&r.cur, @intCast(y), row);
    var term: Term = .{};
    feedHistory(&term);
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());
    try answerQuery(&r, &term);
    try testing.expectEqual(@as(usize, 7), term.row);
    try testing.expectEqual(@as(u16, 3), r.painted_rows);

    // The window is dragged under the band. What the screen holds is
    // the bottom two rows of the band, the band still occupies three,
    // and the row the clip pushed out of reach is the region's now.
    term.resizeRows(2);
    try r.resize(Term.cols, 2, 3);
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    term.feed(t2.bytes());
    try answerQuery(&r, &term);
    try testing.expectEqualStrings(band[1], term.screenText(0));
    try testing.expectEqualStrings(band[2], term.screenText(1));
    try testing.expectEqual(@as(usize, 1), term.screenRow());
    try testing.expectEqual(@as(u16, 3), r.painted_rows);
    try testing.expectEqual(@as(usize, 1), r.owned.items.len);

    // Churn while the window is still short. Each redraw of a band the
    // screen cannot hold re-bases it from the top of the walk, the
    // terminal scrolls that repaint past the line above it, and the band
    // comes back one row lower with another line stranded — so a session
    // that keeps redrawing a three-row band on a two-row window stacks
    // one retired layer per frame. Every one of them is the Region's, and
    // every one of them is taken back when the window returns.
    const churn = [_][3][]const u8{
        .{ "gg0", "gg1", "gg2" },
        .{ "hh0", "hh1", "hh2" },
    };
    for (churn) |set| {
        // The app re-lays its band out, REPLACING each row it paints: a
        // shorter string drawn over a longer one leaves the old tail in
        // the Buffer, and the Buffer is what the frame emits.
        for (set, 0..) |row, y| {
            try clearRow(&r.cur, @intCast(y), r.cur.width);
            try drawRow(&r.cur, @intCast(y), row);
        }
        var tw: TestWriter = .{};
        tw.init();
        try r.render(&tw.w);
        term.feed(tw.bytes());
        try answerQuery(&r, &term);
        try testing.expectEqual(@as(u16, 3), r.painted_rows);
        try testing.expectEqual(@as(usize, 1), term.screenRow());
    }
    // Three retired lines: the clip's own, and one per churned frame.
    // They are one RUN of the band's own rows, which is all the reclaim
    // pass folds them into — without a declared model a group is a
    // distance, and an entry per stranded line would be the ledger
    // growing for a length it could say once.
    try testing.expectEqual(@as(usize, 1), r.owned.items.len);
    try testing.expectEqual(@as(u32, churn.len + 1), r.owned.items[0].rows);
    const last = churn[churn.len - 1];
    const moved = term.row - 2;
    for (last, 0..) |row, y| try testing.expectEqualStrings(row, term.text(moved + y));

    // The window returns the three stranded lines. Reclamation moves
    // the band back over them, directly below the five committed rows.
    term.resizeRows(Term.rows);
    try r.resize(Term.cols, Term.rows, 3);
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    term.feed(t3.bytes());
    // The restore retired the reach, so this frame cannot walk up to the
    // lines the clip stranded; its own reply measures them and the frame
    // after that takes exactly those back.
    try answerQuery(&r, &term);
    var reclaimed: TestWriter = .{};
    reclaimed.init();
    try r.render(&reclaimed.w);
    term.feed(reclaimed.bytes());
    try testing.expectEqual(@as(u16, 3), r.painted_rows);
    try testing.expectEqual(@as(usize, 0), r.owned.items.len);
    const reclaimed_top = moved - churn.len - 1;
    for (last, 0..) |row, y| {
        try testing.expectEqualStrings(row, term.text(reclaimed_top + y));
    }
    try testing.expectEqual(@as(usize, 0), term.col);
    // Nothing of the band's is anywhere but on its own rows: not the
    // lines the window handed back, and not the churned content either.
    for (0..Term.rows) |row| {
        const text = term.text(row);
        var owned = std.mem.eql(u8, text, "");
        for (history_rows) |h| owned = owned or std.mem.eql(u8, text, h);
        for (last) |b| owned = owned or std.mem.eql(u8, text, b);
        if (!owned) try testing.expectEqualStrings("", text);
    }

    // The next keystroke still belongs to the live band, on the rows the
    // band is on now.
    try drawRow(&r.cur, 0, "hhx");
    var t4: TestWriter = .{};
    t4.init();
    try r.render(&t4.w);
    term.feed(t4.bytes());
    try testing.expectEqualStrings("hhx", term.text(reclaimed_top));
    try testing.expectEqualStrings(last[1], term.text(reclaimed_top + 1));
    try testing.expectEqualStrings(last[2], term.text(reclaimed_top + 2));
    for (history_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.text(y));
}

test "region: a queued row waits out a band that covers the window and lands when it does not" {
    // Three rows on a two-row window: the band's physical extent is past
    // what the window shows, so the band's own top row IS the window's
    // first row and there is nothing above it that any frame may write.
    // A queued row cannot go out this tick, and the honest answer to that
    // is silence — not the `.physical` frame a flush would otherwise
    // select, which repaints the band, strands another copy of it and
    // writes nothing. On a band whose cells did not change that drifts
    // the band down a row per tick against a queue that never moves, so
    // the queue waits whole instead, and the first frame whose top is
    // reachable again writes all of it.
    const band = [_][]const u8{ "s0", "s1", "s2" };
    var r = try makeRegion(3, .{});
    defer r.deinit();
    for (band, 0..) |row, y| try drawRow(&r.cur, @intCast(y), row);
    var term: Term = .{};
    feedHistory(&term);
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());
    try answerQuery(&r, &term);
    try testing.expectEqual(@as(usize, 7), term.row);

    // The window is dragged under the band: the row the clip pushed out
    // of reach is the region's now, and the band is the two rows it
    // still fits on.
    term.resizeRows(2);
    try r.resize(Term.cols, 2, 3);
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    term.feed(t2.bytes());
    try answerQuery(&r, &term);
    try testing.expectEqual(@as(usize, 1), term.screenRow());
    try testing.expectEqualStrings(band[1], term.screenText(0));
    try testing.expectEqualStrings(band[2], term.screenText(1));
    const parked = term.row;

    // The app prints above the band and changes no cell of it.
    try r.append(.{ .line = "queued-1" });
    try r.append(.{ .text = "queued-2\nqueued-3" });
    const queued = [_][]const u8{ "queued-1", "queued-2", "queued-3" };
    // Three idle ticks, and not one of them may say anything at all.
    for (0..3) |_| {
        var idle: TestWriter = .{};
        idle.init();
        try r.render(&idle.w);
        term.feed(idle.bytes());
        try testing.expectEqualStrings("", idle.bytes());
    }
    // The band is still the band, on the rows it drifted to once.
    try testing.expectEqual(parked, term.row);
    try testing.expectEqual(@as(usize, 1), term.screenRow());
    try testing.expectEqualStrings(band[1], term.screenText(0));
    try testing.expectEqualStrings(band[2], term.screenText(1));
    // Nothing reached the wire and nothing was dropped: the three rows
    // are still the region's to write.
    for (queued) |row| try testing.expectEqual(@as(usize, 0), rowsHolding(&term, row));

    // The window opens. The band's top is reachable again, so the whole
    // queue lands above it in one frame — each row once, in order — and
    // the committed transcript above that never moves.
    term.resizeRows(Term.rows);
    try r.resize(Term.cols, Term.rows, 3);
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    term.feed(t3.bytes());
    for (queued) |row| try testing.expectEqual(@as(usize, 1), rowsHolding(&term, row));
    for (history_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.text(y));
}

test "region: a width change waits for a reply before it takes a retired row back" {
    // A retirement erase is the one thing this file will never do on a
    // guess: the walk is relative, and a reach that over-states lands on
    // committed content. A column change is exactly that kind of guess,
    // because the cursor's own group is exempt from the repack while the
    // rows above it are not — an xterm measured at 131 columns puts its
    // cursor on screen row 1 over a 131-column group, and at 55 it puts
    // it on row 3 over the same group's three rows. So a width change
    // retires the reach, and the rows stay on the screen until a reply
    // re-establishes where the cursor is.
    var r = try makeNativeRegion(4, .{}, 400);
    defer r.deinit();
    try tagRows(&r.cur, 4, 'a');
    var term: Term = .{};
    feedHistory(&term);
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());
    try testing.expectEqual(@as(usize, 8), term.row);
    try answerQuery(&r, &term);

    // The window is dragged under the band: two of its rows become
    // scrollback and the re-base retires exactly those two.
    term.resizeRows(2);
    try r.resize(Term.cols, 2, 2);
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    term.feed(t2.bytes());
    try testing.expectEqual(@as(u16, 2), r.painted_rows);
    try answerQuery(&r, &term);

    // The window grows back. The retired rows are on the screen again
    // and the erase is owed — but nothing may run on the row the last
    // reply measured, because the next transition is a COLUMN change and
    // a repack moves the cursor down the screen by however many rows
    // the rows above it take.
    term.resizeRows(Term.rows);
    try r.resize(Term.cols, Term.rows, 2);
    try r.resize(40, Term.rows, 2);
    // The app re-lays its band out for the wider terminal, so the rows
    // it paints are its own and cannot be confused with the retired ones
    // the clip left above them.
    try tagRows(&r.cur, 2, 'b');
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    term.feed(t3.bytes());
    // The band is repainted; the two retired rows are untouched, because
    // a COLUMN change retired the reach and no erase may run on a guess.
    try testing.expectEqualStrings(label('b', 0), term.text(7));
    try testing.expectEqualStrings(label('b', 1), term.text(8));
    try testing.expectEqualStrings(label('a', 0), term.text(5));
    try testing.expectEqualStrings(label('a', 1), term.text(6));

    // The reply the frame asked for measures the cursor again, and the
    // next frame takes the rows back — row-scoped, so the transcript
    // above them is never reached.
    try answerQuery(&r, &term);
    var t4: TestWriter = .{};
    t4.init();
    try r.render(&t4.w);
    term.feed(t4.bytes());
    try testing.expectEqualStrings(label('b', 0), term.text(5));
    try testing.expectEqualStrings(label('b', 1), term.text(6));
    try testing.expectEqualStrings("", term.text(7));
    try testing.expectEqualStrings("", term.text(8));
    for (history_rows, 0..) |row, y| try testing.expectEqualStrings(row, term.text(y));
}

test "region: a frame that dies staging across a width change leaves the snapshot retryable" {
    // The external resize moved the drawing buffer to the new grid. The
    // committed snapshot is the OTHER half of the publish — a frame
    // copies one grid into it — so the two have to stand on the same
    // shape at the instant of that copy. A frame that dies staging its
    // bytes must leave both exactly as they were, and the retry must
    // still be able to publish.
    var r = try makeRegion(3, .{});
    defer r.deinit();
    try fillBand(&r.cur, "narrow");
    var term: Term = .{};
    feedHistory(&term);
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    term.feed(t1.bytes());
    try testing.expectEqual(@as(usize, 7), term.row);

    try r.resize(120, Term.rows, 3);
    // The app lays the band out for the new width, REPLACING each row it
    // paints: the reshape carries "narrow" across, and a shorter string
    // drawn over it leaves its tail in the Buffer as a cell the frame
    // emits like any other.
    for (0..r.cur.height) |y| try clearRow(&r.cur, @intCast(y), r.cur.width);
    try fillBand(&r.cur, "wider");
    var tiny: [16]u8 = undefined;
    var narrow: std.Io.Writer = .fixed(&tiny);
    try testing.expectError(error.WriteFailed, r.render(&narrow));
    // The frame died with nothing written: the extent, the repaint
    // still owed and the committed snapshot are the last good frame's.
    try testing.expectEqual(@as(u16, 3), r.painted_rows);
    try testing.expectEqual(@as(usize, 80), r.prev.width);
    try testing.expectEqual(@as(usize, 120), r.cur.width);

    // The retry publishes into a snapshot the frame itself brought onto
    // the new shape, and paints the band there.
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    term.feed(t2.bytes());
    try testing.expectEqual(@as(usize, 120), r.prev.width);
    try testing.expectEqual(@as(u16, 3), r.painted_rows);
    const base = term.row - 2;
    for (0..3) |y| try testing.expectEqualStrings("wider", term.text(base + y));
    try testing.expectEqual(@as(usize, 0), term.col);
}

// Allocation failure must not look like an empty retention ledger.
test "region: pending history query reports allocation failure without losing receipts" {
    var r = try makeRegion(1, .{});
    defer r.deinit();
    try r.writeHistory(.{ .id = 7, .rows = &.{"retained"}, .kind = .append });

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    r.gpa = failing.allocator();
    defer r.gpa = testing.allocator;
    try testing.expectError(error.OutOfMemory, r.historyPending());
    try testing.expect(r.historyRetained(7));
    try testing.expectEqual(@as(u64, 7), r.historyWatermark());

    r.gpa = testing.allocator;
    try testing.expectEqualSlices(u64, &.{7}, try r.historyPending());
}

// An unknown absolute anchor must not emit an image command at terminal row zero.
test "region: image placement refuses an unmeasured anchor without output" {
    var r = try makeRegion(2, .{});
    defer r.deinit();
    var t: TestWriter = .{};
    t.init();
    try testing.expectError(error.AnchorUnmeasured, r.placeAt(&t.w, 0, 1, .{ .id = 1 }));
    try testing.expectEqualStrings("", t.bytes());
}

test "region: automatic history ids report exhaustion after the maximum accepted id" {
    var r = try makeRegion(1, .{});
    defer r.deinit();
    try r.writeHistory(.{
        .id = std.math.maxInt(u64),
        .rows = &.{"last"},
        .kind = .append,
    });
    try testing.expectError(error.HistoryIdExhausted, r.writeTranscript(&.{"not admitted"}));
    try testing.expectEqual(std.math.maxInt(u64), r.historyWatermark());
    try testing.expectEqual(@as(usize, 1), (try r.historyPending()).len);
}

test "region: repaintAll repaints a band whose geometry did not change" {
    // A resize signal that ends on the size the band already has (a window
    // dragged narrow and back between two polls) records nothing through
    // `resize`, yet the terminal cut the cursor's row on the way. The
    // repaint request is what brings the row back.
    var r = try makeRegion(2, .{});
    defer r.deinit();
    try drawRow(&r.cur, 0, "header");
    try drawRow(&r.cur, 1, "the quick brown fox");
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    try r.resize(r.width, Term.rows, 2);
    var idle: TestWriter = .{};
    idle.init();
    try r.render(&idle.w);
    try testing.expectEqualStrings("", idle.bytes());

    try r.resize(r.width, Term.rows, 2);
    r.repaintAll();
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try testing.expectEqual(@as(usize, 1), count(t2.bytes(), "header"));
    // Spaces go out as cursor moves, so match a single word.
    try testing.expectEqual(@as(usize, 1), count(t2.bytes(), "brown"));
}
