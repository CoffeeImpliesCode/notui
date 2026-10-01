//! Keybinding declaration and hint rendering (ROADMAP D3).
//!
//! The app declares a binding ONCE — an opaque `ActionId`, a `chord` of
//! `KeyMatch` steps, an optional `description`, an optional display
//! `hint` — and the `Keymap` gives back both matching and the hint row.
//! `bind` copies everything it keeps into the keymap's arena, so the app
//! may pass stack temporaries; `lookup`, `resolve`, `matchChord`, `chord`
//! and `renderHints` never allocate.
//!
//! # Chords and precedence
//!
//! A chord is a sequence of `KeyMatch` steps; each step carries a
//! codepoint plus the modifiers it REQUIRES. Steps are matched with
//! `Key.matches`, so caps-lock/num-lock stripping and the text /
//! shifted-codepoint fallbacks are inherited from the input layer, never
//! reimplemented here.
//!
//! `resolve` ranks the bindings whose FIRST step matches the pressed key:
//!
//! 1. an exact binding (chord length 1) beats any multi-key prefix;
//! 2. otherwise the LONGEST chord wins (the most specific prefix);
//! 3. ties go to the binding declared first.
//!
//! `lookup` is the one-call form of `resolve`: it reports the winning
//! action whether the key completed a binding or merely starts one, so it
//! is safe when every binding is a single key. `matchChord` completes a
//! sequence with an exact whole-chord match; apps that buffer a sequence
//! themselves use `resolve` to learn it is pending, then `matchChord`.
//!
//! # Hints
//!
//! `renderHints` draws `hint description` pairs into a `Buffer` with the
//! same discipline as the base-ui components: no ANSI, no allocation, no
//! cursor movement. `now` keeps the component shape and is ignored — a
//! hint row never animates. The row is clipped at the buffer's right
//! edge; a pair that does not fit whole is drawn with a trailing "…" and
//! rendering stops, so the returned column count never exceeds
//! `buf.width - x`.
//!
//! A binding without an explicit hint gets one derived from its chord
//! (`ctrl+shift+s`, `g x`, `f5`); `bind` computes it once, so the draw
//! path stays allocation-free. Modifier prefixes print in the fixed
//! order ctrl, alt, shift, super, hyper, meta, and chord steps are joined
//! with a space.

const std = @import("std");
const Key = @import("Key.zig");
const Buffer = @import("buffer.zig").Buffer;
const Style = @import("style.zig").Style;
const Width = @import("width.zig");
const Clock = @import("component/component.zig").Clock;

/// An opaque action identifier. The app owns the numbering (its own enum
/// through `fromEnum`, or a raw integer through `init`); the keymap only
/// stores and compares ids and never interprets the value.
pub const ActionId = struct {
    value: u32,

    pub fn init(value: u32) ActionId {
        return .{ .value = value };
    }

    /// Wrap an app-defined enum value (`@intFromEnum`, so a tagged enum
    /// with payload-less variants works unchanged).
    pub fn fromEnum(value: anytype) ActionId {
        return .{ .value = @intCast(@intFromEnum(value)) };
    }

    pub fn eql(a: ActionId, b: ActionId) bool {
        return a.value == b.value;
    }
};

/// One chord step: the codepoint to match plus the modifiers it requires.
/// `mods` may carry caps_lock/num_lock; `Key.matches` strips both from
/// each side, so a declaration is not sensitive to lock state.
pub const KeyMatch = struct {
    codepoint: u21,
    mods: Key.Modifiers = .{},
};

/// A stored binding: everything the keymap owns a copy of.
pub const Binding = struct {
    action: ActionId,
    /// Chord steps, owned by the keymap's arena.
    chord: []const KeyMatch,
    /// Human description, owned by the keymap's arena.
    description: ?[]const u8 = null,
    /// Display form for the hint row, owned by the keymap's arena.
    hint: []const u8 = "",
};

/// A binding as the app declares it. `bind` copies every slice, so
/// temporaries and stack literals are fine.
pub const Decl = struct {
    action: ActionId,
    /// Chord steps; an empty chord is rejected with `error.EmptyChord`.
    chord: []const KeyMatch,
    description: ?[]const u8 = null,
    /// Display form override; null derives one from the chord.
    hint: ?[]const u8 = null,
};

/// What a pressed key did, per `Keymap.resolve`.
pub const Resolution = union(enum) {
    /// No binding starts with this key.
    none,
    /// The key completed a single-key binding.
    action: ActionId,
    /// The key starts a longer chord; feed the rest to `matchChord`.
    pending: ActionId,
};

/// Which bindings `renderHints` draws.
pub const Selection = struct {
    /// Render only these actions, in this order; null renders every
    /// action in declaration order.
    actions: ?[]const ActionId = null,
    /// Stop after this many `hint description` pairs; null = no cap.
    max_pairs: ?usize = null,
    /// Drawn between pairs, in the default style.
    separator: []const u8 = "  ",
    /// Style for the key hint cells.
    key_style: Style = .{},
    /// Style for the description cells (and the single space before one).
    desc_style: Style = .{},
};

/// Errors `Keymap.bind` can return. Matching and rendering cannot fail.
pub const BindError = error{
    /// The declared chord has no steps.
    EmptyChord,
    OutOfMemory,
};

/// The app's keymap: bindings grouped by action, all storage in one
/// arena. A Keymap must not be copied after `init` (its arena hands out
/// pointers into itself); hold it in a variable or a stable container.
pub const Keymap = struct {
    arena: std.heap.ArenaAllocator,
    /// Bindings per action, in declaration order.
    groups: std.ArrayList(ActionGroup) = .empty,

    /// All bindings that share one action id.
    pub const ActionGroup = struct {
        action: ActionId,
        bindings: std.ArrayList(Binding) = .empty,
    };

    pub fn init(gpa: std.mem.Allocator) Keymap {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    /// Free every chord, description, hint and list. All internal
    /// allocations come from the arena, so this is the only call needed.
    pub fn deinit(self: *Keymap) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Declare one binding. The chord and strings are copied into the
    /// keymap's arena. Rejected: an empty chord (`error.EmptyChord`).
    pub fn bind(self: *Keymap, decl: Decl) BindError!void {
        if (decl.chord.len == 0) return error.EmptyChord;
        const arena = self.arena.allocator();

        const steps = try arena.dupe(KeyMatch, decl.chord);
        errdefer arena.free(steps);
        const hint = if (decl.hint) |h|
            try arena.dupe(u8, h)
        else
            deriveHint(arena, steps) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // The allocating sink has no failure mode other than
                // OOM, so the writer never reports WriteFailed; map it
                // instead of leaking it into `BindError`.
                error.WriteFailed => unreachable,
            };
        errdefer arena.free(hint);
        const description: ?[]const u8 = if (decl.description) |d| try arena.dupe(u8, d) else null;

        const known = self.findGroup(decl.action) != null;
        const group = self.findGroup(decl.action) orelse blk: {
            try self.groups.append(arena, .{ .action = decl.action });
            break :blk &self.groups.items[self.groups.items.len - 1];
        };
        group.bindings.append(arena, .{
            .action = decl.action,
            .chord = steps,
            .description = description,
            .hint = hint,
        }) catch |err| {
            // Do not leave an empty group behind for a failed bind.
            if (!known) _ = self.groups.pop();
            return err;
        };
    }

    /// The action of the most specific binding that starts with `key`
    /// (see the module doc for the ranking). Returns null when nothing
    /// matches. Allocation-free. Use `resolve` when an incomplete chord
    /// must be told apart from a completed one.
    pub fn lookup(self: *const Keymap, key: Key) ?ActionId {
        const binding = self.bestBinding(key) orelse return null;
        return binding.action;
    }

    /// Like `lookup`, but says whether the key completed a binding or
    /// starts a longer chord. Allocation-free.
    pub fn resolve(self: *const Keymap, key: Key) Resolution {
        const binding = self.bestBinding(key) orelse return .none;
        return if (binding.chord.len == 1)
            .{ .action = binding.action }
        else
            .{ .pending = binding.action };
    }

    /// Match `keys` against chords of exactly that length, step by step
    /// with `Key.matches`; the binding declared first wins when two
    /// bindings share a chord. An empty sequence or a length mismatch
    /// returns null. Allocation-free.
    pub fn matchChord(self: *const Keymap, keys: []const Key) ?ActionId {
        if (keys.len == 0) return null;
        for (self.groups.items) |group| {
            for (group.bindings.items) |binding| {
                if (binding.chord.len != keys.len) continue;
                if (chordMatches(binding.chord, keys)) return binding.action;
            }
        }
        return null;
    }

    /// Every binding declared for `action`, in declaration order; null
    /// when the action was never bound. The slice is owned by the keymap
    /// and stays valid until `deinit`.
    pub fn chord(self: *const Keymap, action: ActionId) ?[]const Binding {
        for (self.groups.items) |group| {
            if (group.action.eql(action)) return group.bindings.items;
        }
        return null;
    }

    /// Draw `hint description` pairs at (x, y) and return the columns
    /// consumed (never more than `buf.width - x`). Out-of-band calls
    /// (`y >= buf.height`, `x >= buf.width`) draw nothing. `now` is
    /// ignored: hints are static. Allocation-free.
    pub fn renderHints(
        self: *const Keymap,
        buf: *Buffer,
        x: u16,
        y: u16,
        now: Clock,
        which: Selection,
    ) !u16 {
        _ = now; // component-shaped, but a hint row never animates
        if (y >= buf.height or x >= buf.width) return 0;

        var col: u16 = x;
        var drawn: usize = 0;
        var cursor: GroupCursor = .{ .map = self, .which = which };
        while (cursor.next()) |bindings| {
            for (bindings) |binding| {
                if (which.max_pairs) |max| {
                    if (drawn >= max) return col - x;
                }
                const desc_w: usize = if (binding.description) |d| 1 + Width.strWidth(d) else 0;
                const pair_w: usize = Width.strWidth(binding.hint) + desc_w;
                const sep_w: usize = if (col > x) Width.strWidth(which.separator) else 0;
                const avail: usize = buf.width - col;

                if (sep_w + pair_w <= avail) {
                    if (sep_w > 0) col += try buf.draw(.{}, which.separator, col, y);
                    col += try buf.draw(which.key_style, binding.hint, col, y);
                    if (binding.description) |d| {
                        col += try buf.draw(which.desc_style, " ", col, y);
                        col += try buf.draw(which.desc_style, d, col, y);
                    }
                    drawn += 1;
                    continue;
                }

                // Does not fit whole: clip this pair and stop the row.
                var rem: usize = buf.width - col;
                if (sep_w > 0 and rem > sep_w) {
                    col += try buf.draw(.{}, which.separator, col, y);
                    rem = buf.width - col;
                }
                col += try drawClipped(buf, which.key_style, binding.hint, rem, col, y);
                rem = buf.width - col;
                if (binding.description) |d| {
                    if (rem > 1) {
                        col += try buf.draw(which.desc_style, " ", col, y);
                        rem = buf.width - col;
                    }
                    col += try drawClipped(buf, which.desc_style, d, rem, col, y);
                }
                return col - x;
            }
        }
        return col - x;
    }

    fn findGroup(self: *Keymap, action: ActionId) ?*ActionGroup {
        for (self.groups.items) |*group| {
            if (group.action.eql(action)) return group;
        }
        return null;
    }

    /// The winning binding for a pressed key: exact beats prefix, then
    /// longest chord, then declaration order (strictly-greater keeps the
    /// first declared candidate).
    fn bestBinding(self: *const Keymap, key: Key) ?*const Binding {
        var best: ?*const Binding = null;
        for (self.groups.items) |group| {
            for (group.bindings.items) |*binding| {
                const first = binding.chord[0];
                if (!key.matches(first.codepoint, first.mods)) continue;
                if (best) |cur| {
                    const exact_new = binding.chord.len == 1;
                    const exact_cur = cur.chord.len == 1;
                    if (exact_new == exact_cur and binding.chord.len <= cur.chord.len) continue;
                    if (!exact_new and exact_cur) continue;
                }
                best = binding;
            }
        }
        return best;
    }

    /// Iterates the binding groups `Selection` asks for: listed actions in
    /// the listed order with duplicates preserved, or every group in
    /// declaration order when `which.actions` is null.
    const GroupCursor = struct {
        map: *const Keymap,
        which: Selection,
        index: usize = 0,

        fn next(self: *GroupCursor) ?[]const Binding {
            if (self.which.actions) |ids| {
                while (self.index < ids.len) {
                    const bindings = self.map.chord(ids[self.index]);
                    self.index += 1;
                    if (bindings) |found| return found;
                }
                return null;
            }
            if (self.index >= self.map.groups.items.len) return null;
            const group = self.map.groups.items[self.index];
            self.index += 1;
            return group.bindings.items;
        }
    };
};

/// Whether every chord step matches its key in order.
fn chordMatches(chord: []const KeyMatch, keys: []const Key) bool {
    for (chord, keys) |step, key| {
        if (!key.matches(step.codepoint, step.mods)) return false;
    }
    return true;
}

/// Draw `text` at (x, y) limited to `budget` columns, with a trailing
/// "…" when it does not fit whole. No allocation: the fitting prefix ends
/// on a grapheme boundary found by iteration, and the ellipsis is a
/// constant. Returns the columns consumed (never more than `budget`).
fn drawClipped(buf: *Buffer, style: Style, text: []const u8, budget: usize, x: u16, y: u16) !u16 {
    if (budget == 0) return 0;
    if (Width.strWidth(text) <= budget) return buf.draw(style, text, x, y);

    const ellipsis: []const u8 = "…";
    const trunc_cols = budget -| Width.strWidth(ellipsis);
    var end: usize = 0;
    var width: usize = 0;
    var off: usize = 0;
    while (off < text.len) {
        const glen = Width.firstGraphemeLen(text[off..]);
        if (glen == 0) break; // defensive: no progress possible
        const grapheme = text[off..][0..glen];
        off += glen;
        const gw = Width.graphemeWidth(grapheme);
        if (gw <= 0) { // zero-width: keep glued on to the prefix
            end = off;
            continue;
        }
        const wu: usize = if (gw >= 2) 2 else 1;
        if (width + wu > trunc_cols) break;
        width += wu;
        end = off;
    }

    var used: u16 = 0;
    if (end > 0) used += try buf.draw(style, text[0..end], x, y);
    if (budget > used) used += try buf.draw(style, ellipsis, x + used, y);
    return used;
}

/// Build the default hint for `chord`: each step as modifier prefixes plus
/// a key name, steps joined with a space.
fn deriveHint(gpa: std.mem.Allocator, chord: []const KeyMatch) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (chord, 0..) |step, i| {
        if (i > 0) try out.writer.writeByte(' ');
        try writeKeyMatch(&out.writer, step);
    }
    return out.toOwnedSlice();
}

/// Write one chord step's display form.
fn writeKeyMatch(w: *std.Io.Writer, step: KeyMatch) !void {
    // A control codepoint IS the ctrl encoding of its letter (ctrl+c
    // arrives as 0x03), so print "ctrl" only once.
    const implied_ctrl = step.codepoint >= 0x01 and step.codepoint <= 0x1A;
    if (step.mods.ctrl or implied_ctrl) try w.writeAll("ctrl+");
    if (step.mods.alt) try w.writeAll("alt+");
    if (step.mods.shift) try w.writeAll("shift+");
    if (step.mods.super) try w.writeAll("super+");
    if (step.mods.hyper) try w.writeAll("hyper+");
    if (step.mods.meta) try w.writeAll("meta+");
    try writeBaseName(w, step.codepoint);
}

/// Write the bare key name for a codepoint: a special-key name, the
/// control letter, the printable character itself, or `U+XXXX`.
fn writeBaseName(w: *std.Io.Writer, cp: u21) !void {
    if (cp >= Key.f1 and cp <= Key.f35) return w.print("f{d}", .{cp - Key.f1 + 1});
    if (cp >= Key.kp_0 and cp <= Key.kp_9) return w.print("kp_{d}", .{cp - Key.kp_0});
    switch (cp) {
        Key.space => return w.writeAll("space"),
        Key.tab => return w.writeAll("tab"),
        Key.enter => return w.writeAll("enter"),
        Key.escape => return w.writeAll("escape"),
        Key.backspace => return w.writeAll("backspace"),
        Key.insert => return w.writeAll("insert"),
        Key.delete => return w.writeAll("delete"),
        Key.left => return w.writeAll("left"),
        Key.right => return w.writeAll("right"),
        Key.up => return w.writeAll("up"),
        Key.down => return w.writeAll("down"),
        Key.page_up => return w.writeAll("page_up"),
        Key.page_down => return w.writeAll("page_down"),
        Key.home => return w.writeAll("home"),
        Key.end => return w.writeAll("end"),
        else => {},
    }
    if (cp <= 0x1A and cp >= 0x01) return w.writeByte('a' + @as(u8, @intCast(cp - 1)));
    if (cp >= 0x20 and cp <= 0x7E) return w.writeByte(@intCast(cp));
    return w.print("U+{X:0>4}", .{cp});
}

test {
    std.testing.refAllDecls(@This());
}

const test_alloc = std.testing.allocator;

/// One row's drawn text: the cell graphemes in order (a wide
/// continuation contributes nothing; an untouched cell contributes its
/// default space) with trailing blanks trimmed, so a row compares equal
/// to the text the widget drew.
fn rowText(buf: *const Buffer, y: usize, out: []u8) []const u8 {
    var n: usize = 0;
    var x: usize = 0;
    while (x < buf.width) : (x += 1) {
        const cell = buf.get(@intCast(x), @intCast(y));
        if (cell.wide) continue; // covered by the lead cell
        @memcpy(out[n..][0..cell.grapheme.len], cell.grapheme);
        n += cell.grapheme.len;
    }
    var end = n;
    while (end > 0 and out[end - 1] == ' ') end -= 1;
    return out[0..end];
}

fn ev(codepoint: u21, mods: Key.Modifiers) Key {
    return .{ .codepoint = codepoint, .mods = mods };
}

fn expectAction(expected: u32, got: ?ActionId) !void {
    try std.testing.expect(got != null);
    try std.testing.expectEqual(expected, got.?.value);
}

/// Whether a resolution reported no binding.
fn isNone(r: Resolution) bool {
    return switch (r) {
        .none => true,
        else => false,
    };
}

/// The action of a completed single-key binding, or null.
fn completedAction(r: Resolution) ?ActionId {
    return switch (r) {
        .action => |a| a,
        else => null,
    };
}

/// The action of a pending multi-key chord, or null.
fn pendingAction(r: Resolution) ?ActionId {
    return switch (r) {
        .pending => |a| a,
        else => null,
    };
}

/// Wraps an allocator and counts `alloc` calls, to prove a code path
/// allocates nothing.
const CountingAllocator = struct {
    parent: std.mem.Allocator,
    count: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.parent.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.parent.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.parent.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, alignment, ret_addr);
    }
};

test "keybindings: single key binds and looks up" {
    var km = Keymap.init(test_alloc);
    defer km.deinit();
    try km.bind(.{ .action = .init(1), .chord = &.{.{ .codepoint = 'a' }} });

    try expectAction(1, km.lookup(ev('a', .{})));
    try std.testing.expect(km.lookup(ev('b', .{})) == null);
}

test "keybindings: a multi-key chord is pending on its first key" {
    var km = Keymap.init(test_alloc);
    defer km.deinit();
    try km.bind(.{ .action = .init(2), .chord = &.{
        .{ .codepoint = 'g' },
        .{ .codepoint = 'x' },
    } });

    const pending = km.resolve(ev('g', .{}));
    try std.testing.expectEqual(@as(u32, 2), pendingAction(pending).?.value);
    try std.testing.expect(completedAction(pending) == null);

    // Only the first step starts the chord; the second does not.
    try std.testing.expect(km.lookup(ev('g', .{})) != null);
    try std.testing.expect(km.lookup(ev('x', .{})) == null);

    // The whole chord completes it; a partially or overly long sequence
    // does not.
    try expectAction(2, km.matchChord(&.{ ev('g', .{}), ev('x', .{}) }));
    try std.testing.expect(km.matchChord(&.{ev('g', .{})}) == null);
    try std.testing.expect(km.matchChord(&.{ ev('g', .{}), ev('x', .{}), ev('y', .{}) }) == null);
    try std.testing.expect(km.matchChord(&.{ ev('g', .{}), ev('y', .{}) }) == null);
}

test "keybindings: a modifier mismatch does not match" {
    var km = Keymap.init(test_alloc);
    defer km.deinit();
    try km.bind(.{ .action = .init(3), .chord = &.{.{ .codepoint = 's', .mods = .{ .ctrl = true } }} });

    try expectAction(3, km.lookup(ev('s', .{ .ctrl = true })));
    try std.testing.expect(km.lookup(ev('s', .{})) == null);
    try std.testing.expect(km.lookup(ev('s', .{ .ctrl = true, .shift = true })) == null);
    try std.testing.expect(km.lookup(ev('s', .{ .alt = true })) == null);
}

test "keybindings: lookups inherit caps-lock, num-lock and shifted-text semantics" {
    var km = Keymap.init(test_alloc);
    defer km.deinit();
    try km.bind(.{ .action = .init(4), .chord = &.{.{ .codepoint = 'a' }} });
    try km.bind(.{ .action = .init(5), .chord = &.{.{ .codepoint = ':' }} });

    // Key.matches strips caps_lock/num_lock, so lock state cannot break
    // a binding.
    try expectAction(4, km.lookup(.{
        .codepoint = 'a',
        .mods = .{ .caps_lock = true, .num_lock = true },
    }));
    // A real modifier difference still fails.
    try std.testing.expect(km.lookup(ev('a', .{ .ctrl = true })) == null);
    // Shift+; reports ':' through text/shifted_codepoint: the ':' binding
    // matches without asking the app to spell out the shift.
    try expectAction(5, km.lookup(.{
        .codepoint = ';',
        .shifted_codepoint = ':',
        .mods = .{ .shift = true },
        .text = ":",
    }));
}

test "keybindings: the longest chord wins among prefixes" {
    var km = Keymap.init(test_alloc);
    defer km.deinit();
    try km.bind(.{ .action = .init(10), .chord = &.{
        .{ .codepoint = 'g' },
        .{ .codepoint = 'x' },
    } });
    try km.bind(.{ .action = .init(11), .chord = &.{
        .{ .codepoint = 'g' },
        .{ .codepoint = 'x' },
        .{ .codepoint = 'y' },
    } });

    // Both chords start with 'g'; the three-step chord is the most
    // specific. Shortest-first precedence would report 10 here.
    try expectAction(11, km.lookup(ev('g', .{})));
    const pending = km.resolve(ev('g', .{}));
    try std.testing.expectEqual(@as(u32, 11), pendingAction(pending).?.value);

    // Completion uses the exact sequence length.
    try expectAction(10, km.matchChord(&.{ ev('g', .{}), ev('x', .{}) }));
    try expectAction(11, km.matchChord(&.{ ev('g', .{}), ev('x', .{}), ev('y', .{}) }));
}

test "keybindings: an exact binding beats a longer prefix" {
    // Both declaration orders must give the same answer.
    const orders = [_]struct { exact_first: bool }{
        .{ .exact_first = true },
        .{ .exact_first = false },
    };
    for (orders) |order| {
        var km = Keymap.init(test_alloc);
        defer km.deinit();
        const exact: Decl = .{ .action = .init(20), .chord = &.{.{ .codepoint = 'a' }} };
        const prefix: Decl = .{ .action = .init(21), .chord = &.{
            .{ .codepoint = 'a' },
            .{ .codepoint = 'b' },
        } };
        if (order.exact_first) {
            try km.bind(exact);
            try km.bind(prefix);
        } else {
            try km.bind(prefix);
            try km.bind(exact);
        }

        // Longest-first precedence would report the pending prefix (21)
        // here.
        const r = km.resolve(ev('a', .{}));
        try std.testing.expectEqual(@as(u32, 20), completedAction(r).?.value);
        try std.testing.expect(pendingAction(r) == null);
        try expectAction(20, km.lookup(ev('a', .{})));

        // The longer chord is still reachable as a sequence.
        try expectAction(21, km.matchChord(&.{ ev('a', .{}), ev('b', .{}) }));
    }
}

test "keybindings: an empty keymap resolves nothing" {
    var km = Keymap.init(test_alloc);
    defer km.deinit();

    try std.testing.expect(km.lookup(ev('a', .{})) == null);
    try std.testing.expect(isNone(km.resolve(ev('a', .{}))));
    try std.testing.expect(km.matchChord(&.{ev('a', .{})}) == null);
    try std.testing.expect(km.matchChord(&.{}) == null);
    try std.testing.expect(km.chord(.init(1)) == null);
}

test "keybindings: an empty chord is rejected" {
    var km = Keymap.init(test_alloc);
    defer km.deinit();
    try std.testing.expectError(error.EmptyChord, km.bind(.{ .action = .init(1), .chord = &.{} }));
    // The rejected bind leaves no group behind.
    try std.testing.expect(km.chord(.init(1)) == null);
}

test "keybindings: chord() returns every binding of an action" {
    var km = Keymap.init(test_alloc);
    defer km.deinit();
    try km.bind(.{ .action = .init(30), .chord = &.{.{ .codepoint = 'a' }} });
    try km.bind(.{ .action = .init(31), .chord = &.{.{ .codepoint = 'b' }} });
    try km.bind(.{ .action = .init(30), .chord = &.{.{ .codepoint = 'c' }} });

    const bindings = km.chord(.init(30));
    try std.testing.expect(bindings != null);
    try std.testing.expectEqual(@as(usize, 2), bindings.?.len);
    try std.testing.expectEqual(@as(u21, 'a'), bindings.?[0].chord[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'c'), bindings.?[1].chord[0].codepoint);
    try std.testing.expect(bindings.?[0].action.eql(bindings.?[1].action));
    try std.testing.expect(km.chord(.init(99)) == null);
}

test "keybindings: round trip — sources may die, bindings still resolve" {
    // Declared chords live in mutable arrays that are scribbled over
    // right after binding: only a copy can satisfy the lookups below.
    var steps_q = [_]KeyMatch{.{ .codepoint = 'q' }};
    var steps_save = [_]KeyMatch{.{ .codepoint = 's', .mods = .{ .ctrl = true } }};
    var steps_go = [_]KeyMatch{ .{ .codepoint = 'g' }, .{ .codepoint = 'g' } };
    var steps_alt_up = [_]KeyMatch{.{ .codepoint = Key.up, .mods = .{ .alt = true } }};
    var steps_xyz = [_]KeyMatch{
        .{ .codepoint = 'x' },
        .{ .codepoint = 'y' },
        .{ .codepoint = 'z' },
    };

    var km = Keymap.init(test_alloc);
    defer km.deinit();
    try km.bind(.{ .action = .init(40), .chord = &steps_q, .description = "quit" });
    try km.bind(.{ .action = .init(41), .chord = &steps_save, .description = "save" });
    try km.bind(.{ .action = .init(42), .chord = &steps_go, .description = "go" });
    try km.bind(.{ .action = .init(43), .chord = &steps_alt_up, .hint = "shove" });
    try km.bind(.{ .action = .init(44), .chord = &steps_xyz });

    // Overwrite every source chord; a keymap that stored the pointers
    // would now match the poison codepoint instead of the declared one.
    const poison: KeyMatch = .{ .codepoint = 0xDEAD, .mods = .{ .hyper = true } };
    @memset(&steps_q, poison);
    @memset(&steps_save, poison);
    @memset(&steps_go, poison);
    @memset(&steps_alt_up, poison);
    @memset(&steps_xyz, poison);

    // Independently written expectations, resolved by pressing the keys.
    const expect_start = [_]struct { key: Key, action: u32 }{
        .{ .key = ev('q', .{}), .action = 40 },
        .{ .key = ev('s', .{ .ctrl = true }), .action = 41 },
        .{ .key = ev('g', .{}), .action = 42 },
        .{ .key = ev(Key.up, .{ .alt = true }), .action = 43 },
        .{ .key = ev('x', .{}), .action = 44 },
    };
    for (expect_start) |expect| try expectAction(expect.action, km.lookup(expect.key));

    const g_g = [_]Key{ ev('g', .{}), ev('g', .{}) };
    const x_y_z = [_]Key{ ev('x', .{}), ev('y', .{}), ev('z', .{}) };
    try expectAction(42, km.matchChord(&g_g));
    try expectAction(44, km.matchChord(&x_y_z));

    // A step that is never a chord start resolves to nothing.
    try std.testing.expect(km.lookup(ev('y', .{})) == null);
    try std.testing.expect(km.lookup(ev('z', .{})) == null);

    // The stored chords are the declared ones, step for step.
    const stored_q = km.chord(.init(40)).?;
    try std.testing.expectEqual(@as(usize, 1), stored_q.len);
    try std.testing.expectEqual(@as(u21, 'q'), stored_q[0].chord[0].codepoint);
    const stored_xyz = km.chord(.init(44)).?;
    try std.testing.expectEqual(@as(usize, 3), stored_xyz[0].chord.len);
    const want = [_]u21{ 'x', 'y', 'z' };
    for (stored_xyz[0].chord, want) |step, cp| try std.testing.expectEqual(cp, step.codepoint);

    // Hints came from the same declaration: derived, or the override.
    var buf = try Buffer.init(test_alloc, 80, 1);
    defer buf.deinit();
    const used = try km.renderHints(&buf, 0, 0, .fromNanoseconds(0), .{ .separator = " " });
    var row: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "q quit ctrl+s save g g go shove x y z",
        rowText(&buf, 0, &row),
    );
    try std.testing.expectEqual(@as(u16, 37), used);
}

test "keybindings: hints render key/description pairs with styles" {
    var km = Keymap.init(test_alloc);
    defer km.deinit();
    try km.bind(.{
        .action = .init(50),
        .chord = &.{.{ .codepoint = 'q', .mods = .{ .ctrl = true } }},
        .description = "quit",
    });

    var buf = try Buffer.init(test_alloc, 20, 1);
    defer buf.deinit();
    const used = try km.renderHints(&buf, 0, 0, .fromNanoseconds(0), .{
        .key_style = .{ .attrs = .{ .bold = true } },
        .desc_style = .{ .attrs = .{ .dim = true } },
    });

    var row: [64]u8 = undefined;
    try std.testing.expectEqualStrings("ctrl+q quit", rowText(&buf, 0, &row));
    try std.testing.expectEqual(@as(u16, 11), used);
    try std.testing.expect(buf.get(0, 0).style.eql(.{ .attrs = .{ .bold = true } }));
    try std.testing.expect(buf.get(5, 0).style.eql(.{ .attrs = .{ .bold = true } }));
    try std.testing.expect(buf.get(6, 0).style.eql(.{ .attrs = .{ .dim = true } }));
    try std.testing.expect(buf.get(9, 0).style.eql(.{ .attrs = .{ .dim = true } }));
}

test "keybindings: derived hint names" {
    var km = Keymap.init(test_alloc);
    defer km.deinit();
    try km.bind(.{ .action = .init(60), .chord = &.{.{ .codepoint = 0x03, .mods = .{ .ctrl = true } }} });
    try km.bind(.{ .action = .init(61), .chord = &.{.{ .codepoint = 's', .mods = .{ .ctrl = true } }} });
    try km.bind(.{ .action = .init(62), .chord = &.{
        .{ .codepoint = 'g' },
        .{ .codepoint = Key.f5 },
    } });
    try km.bind(.{ .action = .init(63), .chord = &.{.{ .codepoint = Key.up, .mods = .{ .alt = true } }} });
    try km.bind(.{ .action = .init(64), .chord = &.{.{ .codepoint = 'a', .mods = .{ .shift = true } }} });

    var buf = try Buffer.init(test_alloc, 80, 1);
    defer buf.deinit();
    _ = try km.renderHints(&buf, 0, 0, .fromNanoseconds(0), .{ .separator = "|" });
    var row: [128]u8 = undefined;
    // ctrl+c is not "ctrl+ctrl+c": a control codepoint already implies it.
    try std.testing.expectEqualStrings("ctrl+c|ctrl+s|g f5|alt+up|shift+a", rowText(&buf, 0, &row));
}

test "keybindings: hint selection filters, orders and caps pairs" {
    var km = Keymap.init(test_alloc);
    defer km.deinit();
    try km.bind(.{ .action = .init(70), .chord = &.{.{ .codepoint = 'q' }}, .description = "quit" });
    try km.bind(.{ .action = .init(71), .chord = &.{.{ .codepoint = 'w' }}, .description = "write" });
    try km.bind(.{ .action = .init(72), .chord = &.{.{ .codepoint = 'e' }}, .description = "edit" });

    var buf = try Buffer.init(test_alloc, 40, 1);
    defer buf.deinit();
    var row: [64]u8 = undefined;

    // Selected actions render in the selection's order.
    _ = try km.renderHints(&buf, 0, 0, .fromNanoseconds(0), .{
        .actions = &.{ .init(72), .init(70) },
    });
    try std.testing.expectEqualStrings("e edit  q quit", rowText(&buf, 0, &row));

    // Declaration order when nothing is selected, capped by max_pairs.
    buf.clear();
    _ = try km.renderHints(&buf, 0, 0, .fromNanoseconds(0), .{ .max_pairs = 2 });
    try std.testing.expectEqualStrings("q quit  w write", rowText(&buf, 0, &row));

    // An unknown action in the selection renders nothing.
    buf.clear();
    const used = try km.renderHints(&buf, 0, 0, .fromNanoseconds(0), .{ .actions = &.{.init(99)} });
    try std.testing.expectEqual(@as(u16, 0), used);
    try std.testing.expectEqualStrings("", rowText(&buf, 0, &row));
}

test "keybindings: the hint row clips at the buffer edge" {
    var km = Keymap.init(test_alloc);
    defer km.deinit();
    try km.bind(.{
        .action = .init(80),
        .chord = &.{.{ .codepoint = 'q', .mods = .{ .ctrl = true } }},
        .description = "quit",
    });

    // Narrow enough that only the key hint fits: the description is
    // dropped rather than overflow.
    {
        var buf = try Buffer.init(test_alloc, 6, 1);
        defer buf.deinit();
        const used = try km.renderHints(&buf, 0, 0, .fromNanoseconds(0), .{});
        var row: [64]u8 = undefined;
        try std.testing.expectEqual(@as(u16, 6), used);
        try std.testing.expectEqualStrings("ctrl+q", rowText(&buf, 0, &row));
    }
    // Narrower than the key hint: grapheme-safe prefix plus ellipsis.
    {
        var buf = try Buffer.init(test_alloc, 3, 1);
        defer buf.deinit();
        const used = try km.renderHints(&buf, 0, 0, .fromNanoseconds(0), .{});
        var row: [64]u8 = undefined;
        try std.testing.expectEqual(@as(u16, 3), used);
        try std.testing.expectEqualStrings("ct…", rowText(&buf, 0, &row));
    }
}

test "keybindings: hints never overflow, at any width" {
    var km = Keymap.init(test_alloc);
    defer km.deinit();
    try km.bind(.{ .action = .init(90), .chord = &.{.{ .codepoint = 'q' }}, .description = "quit" });
    try km.bind(.{ .action = .init(91), .chord = &.{.{ .codepoint = 'w' }}, .description = "wide 😊" });
    try km.bind(.{ .action = .init(92), .chord = &.{.{ .codepoint = 'e' }}, .description = "edit file" });

    var width: u16 = 1;
    while (width <= 40) : (width += 1) {
        var buf = try Buffer.init(test_alloc, width, 1);
        defer buf.deinit();
        // An offset x must also stay inside the same buffer.
        const used = try km.renderHints(&buf, 0, 0, .fromNanoseconds(0), .{});
        try std.testing.expect(used <= width);

        // Nothing is drawn past the reported extent.
        var x: usize = used;
        while (x < width) : (x += 1) {
            try std.testing.expect(buf.get(@intCast(x), 0).eql(.{}));
        }
        // And the row starts with the first pair whenever it fits whole.
        if (width >= 9) {
            var row: [64]u8 = undefined;
            try std.testing.expect(std.mem.startsWith(u8, rowText(&buf, 0, &row), "q quit"));
        }
    }
}

test "keybindings: out-of-band draws are no-ops" {
    var km = Keymap.init(test_alloc);
    defer km.deinit();
    try km.bind(.{ .action = .init(95), .chord = &.{.{ .codepoint = 'q' }}, .description = "quit" });

    var buf = try Buffer.init(test_alloc, 10, 1);
    defer buf.deinit();
    try std.testing.expectEqual(@as(u16, 0), try km.renderHints(&buf, 10, 0, .fromNanoseconds(0), .{}));
    try std.testing.expectEqual(@as(u16, 0), try km.renderHints(&buf, 0, 1, .fromNanoseconds(0), .{}));
    // Rendering into the right part of a row stops at the buffer's edge:
    // the pair starts at x = 4 and the last column ends it.
    const used = try km.renderHints(&buf, 4, 0, .fromNanoseconds(0), .{});
    try std.testing.expectEqual(@as(u16, 6), used);
    var row: [32]u8 = undefined;
    try std.testing.expectEqualStrings("    q quit", rowText(&buf, 0, &row));
}

test "keybindings: matching and rendering never allocate" {
    var counting: CountingAllocator = .{ .parent = test_alloc };
    var km = Keymap.init(counting.allocator());
    defer km.deinit();
    try km.bind(.{ .action = .init(1), .chord = &.{.{ .codepoint = 'a' }} });
    try km.bind(.{ .action = .init(2), .chord = &.{
        .{ .codepoint = 'g' },
        .{ .codepoint = 'x' },
    } });

    var buf = try Buffer.init(test_alloc, 24, 1);
    defer buf.deinit();

    const before = counting.count;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        _ = km.lookup(ev('a', .{}));
        _ = km.lookup(ev('g', .{}));
        _ = km.lookup(ev('z', .{}));
        _ = km.resolve(ev('g', .{}));
        _ = km.matchChord(&.{ ev('g', .{}), ev('x', .{}) });
        _ = km.chord(.init(2));
        _ = try km.renderHints(&buf, 0, 0, .fromNanoseconds(0), .{});
    }
    try std.testing.expectEqual(before, counting.count);
}
