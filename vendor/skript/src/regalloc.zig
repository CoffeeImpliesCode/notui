const std = @import("std");

const max_regs = 256;

/// Trivial linear-scan register allocator for prototype.
/// Allocates registers from a free list with a hint-based approach.
pub const RegAlloc = struct {
    /// Bitmap of free registers (1 = free).
    free: std.StaticBitSet(max_regs) = std.StaticBitSet(max_regs).initEmpty(),
    /// Next register to try (hint for better cache behavior).
    next_hint: u8 = 1, // r0 reserved for return value
    /// Number of registers used (renaming counter for debug).
    max_used: u8 = 0,

    pub fn init() RegAlloc {
        var self: RegAlloc = .{};
        self.free.setRangeValue(.{ .start = 1, .end = max_regs }, true);
        return self;
    }

    /// Allocate a register. Returns register index (0-255).
    pub fn allocReg(self: *RegAlloc) u8 {
        const r = self.free.findFirstSet() orelse @panic("out of virtual registers");
        self.free.unset(r);
        self.next_hint = @intCast(r);
        if (r > self.max_used) self.max_used = @intCast(r);
        return @intCast(r);
    }

    /// Free a register for reuse.
    pub fn freeReg(self: *RegAlloc, reg: u8) void {
        std.debug.assert(!self.free.isSet(reg));
        self.free.set(reg);
        if (reg < self.next_hint) self.next_hint = reg;
    }

    /// Allocate a contiguous block of `count` registers. Every slot is free
    /// by construction (busy registers are skipped), so a block never
    /// overlaps a live value.
    pub fn allocBlock(self: *RegAlloc, count: u8) u8 {
        var base: u8 = 0;
        var found: bool = false;
        // `<=`: the window starting at i covers [i, i+count-1], so the
        // topmost window starts at max_regs - count — the old `<` bound
        // never checked it (a block could fail to allocate when only the
        // top registers were free).
        var i: u16 = 0;
        while (i <= @as(u16, max_regs) - @as(u16, count)) : (i += 1) {
            var all_free = true;
            for (0..count) |j| {
                if (!self.free.isSet(i + j)) {
                    all_free = false;
                    i += @intCast(j); // skip to the used register
                    break;
                }
            }
            if (all_free) {
                base = @intCast(i);
                found = true;
                break;
            }
        }
        std.debug.assert(found); // must fit in 256 registers for prototype
        for (0..count) |j| self.free.unset(base + @as(usize, j));
        // u16 arithmetic: base + count can exceed 255 (a block touching the
        // top registers would overflow u8 before the -1).
        const block_top: u16 = @as(u16, base) + @as(u16, count) - 1;
        if (block_top > self.max_used) self.max_used = @intCast(block_top);
        return base;
    }

    /// Free a contiguous block.
    pub fn freeBlock(self: *RegAlloc, base: u8, count: u8) void {
        for (0..count) |j| {
            self.free.set(base + @as(usize, j));
        }
    }

    /// True when the block [base, base+count) is entirely free (no busy slot).
    /// A query only — the caller reserves the block with `reserveBlock` before
    /// writing the slots. Windows that overrun the register file are never
    /// free (the caller must use allocBlock for those).
    pub fn blockFree(self: *const RegAlloc, base: u8, count: u8) bool {
        if (@as(u16, base) + @as(u16, count) > max_regs) return false;
        var j: u8 = 0;
        while (j < count) : (j += 1) {
            if (!self.free.isSet(@as(usize, base) + j)) return false;
        }
        return true;
    }

    /// Mark the block [base, base+count) busy at a caller-selected base (the
    /// caller verified `blockFree` first — the block is in range). Mirrors
    /// allocBlock's busy-marking and max_used update without choosing the base.
    pub fn reserveBlock(self: *RegAlloc, base: u8, count: u8) void {
        std.debug.assert(@as(u16, base) + @as(u16, count) <= max_regs);
        for (0..count) |j| self.free.unset(@as(usize, base) + j);
        const block_top: u16 = @as(u16, base) + @as(u16, count) - 1;
        if (block_top > self.max_used) self.max_used = @intCast(block_top);
    }
};

test "RegAlloc basic allocation" {
    var ra = RegAlloc.init();
    const r1 = ra.allocReg();
    try std.testing.expect(r1 == 1); // r0 is reserved, so first is 1
    const r2 = ra.allocReg();
    try std.testing.expect(r2 == 2);
    ra.freeReg(r1);
    const r3 = ra.allocReg();
    try std.testing.expect(r3 == 1); // should reuse freed r1
}

test "RegAlloc block allocation" {
    var ra = RegAlloc.init();
    const base = ra.allocBlock(4);
    try std.testing.expect(base == 1); // first 4 registers after r0
    try std.testing.expect(!ra.free.isSet(1));
    try std.testing.expect(!ra.free.isSet(2));
    try std.testing.expect(!ra.free.isSet(3));
    try std.testing.expect(!ra.free.isSet(4));
    ra.freeBlock(base, 4);
    try std.testing.expect(ra.free.isSet(1));
    try std.testing.expect(ra.free.isSet(2));
    try std.testing.expect(ra.free.isSet(3));
    try std.testing.expect(ra.free.isSet(4));
}

test "RegAlloc max_used tracking" {
    var ra = RegAlloc.init();
    try std.testing.expect(ra.max_used == 0);
    const r1 = ra.allocReg();
    try std.testing.expect(ra.max_used == r1);
    const r2 = ra.allocReg();
    try std.testing.expect(ra.max_used == r2);
    ra.freeReg(r2);
    try std.testing.expect(ra.max_used == r2); // max_used doesn't shrink on free
}

test "RegAlloc block updates max_used" {
    var ra = RegAlloc.init();
    const base = ra.allocBlock(10);
    try std.testing.expect(ra.max_used == base + 10 - 1);
}

test "RegAlloc block allocation finds the topmost window" {
    var ra = RegAlloc.init();
    // Occupy everything below 252, leaving only the topmost window free.
    ra.free.setRangeValue(.{ .start = 1, .end = max_regs - 4 }, false);
    const base = ra.allocBlock(4);
    try std.testing.expectEqual(@as(u8, max_regs - 4), base);
    try std.testing.expect(!ra.free.isSet(base));
    try std.testing.expect(!ra.free.isSet(base + 3));
}

test "RegAlloc blockFree query and reserveBlock" {
    var ra = RegAlloc.init();
    // r0 is never free; a window starting at 0 can never pass blockFree.
    try std.testing.expect(!ra.blockFree(0, 1));
    // Fresh allocator: every window is free.
    try std.testing.expect(ra.blockFree(1, 4));
    try std.testing.expect(ra.blockFree(250, 6));
    // A busy slot fails the query, even if the rest of the window is free.
    const r = ra.allocReg();
    try std.testing.expect(!ra.blockFree(r, 2));
    try std.testing.expect(!ra.blockFree(@as(u8, r - 1), 2));
    // reserveBlock marks the chosen base busy without choosing it.
    try std.testing.expect(ra.blockFree(10, 3));
    ra.reserveBlock(10, 3);
    try std.testing.expect(!ra.blockFree(10, 3));
    try std.testing.expect(!ra.blockFree(8, 3)); // 10 is busy
    try std.testing.expect(!ra.free.isSet(10));
    try std.testing.expect(!ra.free.isSet(12));
    try std.testing.expectEqual(@as(u8, 12), ra.max_used);
    // A later allocBlock must skip the reserved window.
    const base = ra.allocBlock(3);
    try std.testing.expect(base < 10 or base > 12);
    // The reserved block frees like any allocBlock'd block.
    ra.freeBlock(10, 3);
    try std.testing.expect(ra.blockFree(10, 3));
    // A window overrunning the register file is never free.
    try std.testing.expect(!ra.blockFree(255, 2));
    try std.testing.expect(!ra.blockFree(254, 3));
}
