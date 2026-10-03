//! The per-frame view of the session that `update`, `view` and the paint
//! callback receive.
//!
//! `App` builds a fresh `Context` before each model call and keeps it on the
//! stack: `buf`, `width`, `height`, `frame_delta` and `color_profile` are
//! snapshots for that frame only, and a model must not retain the struct
//! itself. `render_requested` is the one field a model writes, and the App
//! reads it back before deciding whether to paint.
//!
//! Two arenas are offered with a strict split, because the frame `Buffer`'s
//! cells borrow their grapheme slices instead of copying them:
//!
//! * `frame_arena` is the session arena. It is never reset while the session
//!   runs: a per-frame reset would hand the same bytes back to the next
//!   frame while the previous frame's `prev` snapshot still points at them,
//!   and unchanged content would then never repaint. It is released by
//!   `App.deinit`.
//! * `scratch_arena` is reset at the top of every tick, every headless frame
//!   and the degraded session's final frame. Anything allocated from it dies
//!   with the frame that allocated it.
//!
//! Text that lands in `buf` cells must therefore come from `frame_arena`, and
//! a scratch allocation must not outlive the frame. The tty, the capability
//! set and the output queue are deliberately not part of this struct.

const std = @import("std");
const Region = @import("region.zig").Region;
const Buffer = @import("buffer.zig").Buffer;
const ColorProfile = @import("color.zig").ColorProfile;

/// One frame's view of the session.
///
/// The value is a borrowed snapshot: `buf` and `region` point at the live
/// frame state, the arenas are owned by the `App`, and `io` is the session's
/// `std.Io`. Nothing here is owned by the model, and nothing must be freed by
/// it. `Context` is not shared across threads; the App calls a model on the
/// loop thread only.
pub const Context = struct {
    /// The session allocator (`App.gpa`): state the model keeps for the whole
    /// session. What it allocates is the model's to release.
    allocator: std.mem.Allocator,
    /// The session arena, reset only when the session ends. Frame cells borrow
    /// their grapheme slices from memory allocated here, so every byte that
    /// reaches `buf` — wrapped or truncated text, formatted numbers, component
    /// labels — must be allocated here, not from `scratch_arena`.
    frame_arena: std.mem.Allocator,
    /// The per-frame arena, reset at the top of every frame before any model
    /// code runs. Use it for layout, sorting and formatting whose result is
    /// consumed within the frame; a slice from a previous frame is dead, and
    /// writing one into `buf` would alias the next frame's memory.
    scratch_arena: std.mem.Allocator,
    /// The `std.Io` the session runs on, for reading the clock
    /// (`std.Io.Timestamp.now(io, .awake)`) and for sleeping. Borrowed for the
    /// session; a model must not close it.
    io: std.Io,
    /// The buffer this frame is painted into: the inline region's `cur`. The
    /// cells borrow their grapheme slices, so they stay valid until the next
    /// frame is painted, and the pointer itself must not be retained.
    buf: *Buffer,
    /// Band width in columns; equal to `region.width`.
    width: u16,
    /// Band height in rows; equal to `region.height`.
    height: u16,
    /// Time elapsed since the previous tick, from the monotonic clock.
    /// `.zero` on the first tick of a session.
    frame_delta: std.Io.Duration,
    /// Ticks entered in this session, including the current tick: 1 on its first
    /// model callback. Zero before the first tick; `frameHeadless` does not advance it.
    frame_count: u64,
    /// The color profile the terminal was detected to support. A session
    /// without a terminal reports `.ansi256`, so a model can pick a palette
    /// without testing for one.
    color_profile: ColorProfile,
    /// Set to true to force a repaint this frame even when the `View`
    /// declaration is unchanged (an animation advanced, a timer fired). The
    /// App clears it before each frame and reads it back afterwards.
    render_requested: bool = false,

    /// The region backing `buf` and the scrollback-above queue. Framework
    /// internals: `App` fills it, `appendAbove` drains it through the region.
    /// A model reads geometry from `width`/`height` instead of reaching in
    /// here.
    region: *Region,

    /// Queue `text` to be flushed above the band into scrollback as one plain
    /// line, and force this frame to render so the flush happens even when the
    /// band itself did not change.
    ///
    /// The queue borrows `text`: it must stay alive and unchanged until the
    /// region has flushed that line or the session ends, which a terminal that
    /// stopped reading can defer indefinitely. On `error.OutOfMemory` nothing
    /// is queued and `render_requested` is left as it was.
    pub fn appendAbove(self: *Context, text: []const u8) std.mem.Allocator.Error!void {
        try self.region.append(.{ .line = text });
        self.render_requested = true;
    }
};

test {
    std.testing.refAllDecls(@This());
}
