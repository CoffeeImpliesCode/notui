//! Module registry: canonical path → entry. Guarded by the scheduler mutex
//! (like the ready queue); entries are arena-owned (rt.static) and live for
//! the runtime lifetime — the registry never frees them.
const std = @import("std");

const skript = @import("root.zig");

pub const Status = enum { loading, loaded, failed };

/// A public name is resolved only when the module finishes. This lets an
/// export precede a local definition or an import of its source module.
pub const ExportSpec = struct {
    pub const Source = union(enum) {
        local: skript.Sym,
        reexport: struct { alias: skript.Sym, public: skript.Sym },
    };
    external: skript.Sym,
    source: Source,
};

pub const ModuleEntry = struct {
    path: []const u8, // canonical absolute path, arena-owned
    status: Status = .loading,
    process: ?*skript.scheduler.Process = null, // the module's process (loading)
    ns: skript.Value = .nil, // the module namespace (loaded)
    err: ?skript.Error = null, // recorded crash (failed)
};

pub const ModuleRegistry = struct {
    entries: std.ArrayList(*ModuleEntry) = .empty,

    /// Find the entry for `path`, or null. Caller holds the scheduler mutex.
    pub fn findLocked(self: *ModuleRegistry, path: []const u8) ?*ModuleEntry {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.path, path)) return e;
        }
        return null;
    }

    /// Find the entry for `path`, or insert a fresh `.loading` entry with
    /// the given process. Returns the (possibly pre-existing) entry. Caller
    /// holds the scheduler mutex; `alloc` is rt.static (the arena).
    pub fn insertLocked(
        self: *ModuleRegistry,
        alloc: std.mem.Allocator,
        path: []const u8,
        proc: ?*skript.scheduler.Process,
    ) !*ModuleEntry {
        if (self.findLocked(path)) |e| return e;
        try self.entries.ensureUnusedCapacity(alloc, 1);
        const entry = try alloc.create(ModuleEntry);
        entry.* = .{ .path = path, .process = proc };
        self.entries.appendAssumeCapacity(entry);
        return entry;
    }
};

test "module registry: find/insert roundtrip" {
    var reg: ModuleRegistry = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expect(reg.findLocked("/a.pt") == null);
    const e1 = try reg.insertLocked(alloc, "/a.pt", null);
    try std.testing.expectEqual(Status.loading, e1.status);
    try std.testing.expect(e1.process == null);
    // Same path: find-or-insert returns the SAME entry.
    const e2 = try reg.insertLocked(alloc, "/a.pt", null);
    try std.testing.expect(e1 == e2);
    try std.testing.expectEqual(@as(usize, 1), reg.entries.items.len);
    // Distinct path appends.
    _ = try reg.insertLocked(alloc, "/b.pt", null);
    try std.testing.expectEqual(@as(usize, 2), reg.entries.items.len);
    try std.testing.expectEqualStrings("/b.pt", reg.findLocked("/b.pt").?.path);
    try std.testing.expect(reg.findLocked("/c.pt") == null);
}

test "module registry: retained entries remain authoritative after growth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var registry: ModuleRegistry = .{};
    const retained = try registry.insertLocked(allocator, "/first.pt", null);
    const initial_capacity = registry.entries.capacity;
    for (0..initial_capacity) |index| {
        const path = try std.fmt.allocPrint(allocator, "/module-{d}.pt", .{index});
        _ = try registry.insertLocked(allocator, path, null);
    }
    retained.status = .failed;
    retained.err = error.Unsupported;
    const current = registry.findLocked("/first.pt") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Status.failed, current.status);
    try std.testing.expectEqual(@as(?skript.Error, error.Unsupported), current.err);
}
