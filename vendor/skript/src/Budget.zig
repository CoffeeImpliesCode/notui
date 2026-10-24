const std = @import("std");
const Budget = @This();

pub const Error = error{Exhausted};
pub const Backend = enum { reader, binder, transform, code, regvm, native, scheduler, formatter };
pub const Resource = enum { work, bytes, objects, nodes, output, processes, paths, depth, retained_bytes };
pub const Reason = enum { quota, lease, overflow };
pub const Schedule = struct { id: u32 = 1, revision: u64 = 1 };

pub const Charge = struct {
    work: u64 = 0,
    bytes: u64 = 0,
    objects: u64 = 0,
    nodes: u64 = 0,
    output: u64 = 0,
    processes: u64 = 0,
    paths: u64 = 0,
};

pub const Limits = struct {
    work: u64,
    bytes: u64 = std.math.maxInt(u64),
    objects: u64 = std.math.maxInt(u64),
    nodes: u64 = std.math.maxInt(u64),
    output: u64 = std.math.maxInt(u64),
    processes: u64 = std.math.maxInt(u64),
    paths: u64 = std.math.maxInt(u64),
    depth: u32 = 1024,
};

pub const Report = struct {
    lineage_id: u64,
    schedule: Schedule,
    backend: Backend,
    resource: Resource,
    reason: Reason,
    limit: u64,
    available: u64,
    requested: ?u64,
    consumed: Charge,
    depth_peak: u32,
};

pub const Snapshot = struct {
    consumed: Charge,
    available: Charge,
    depth_peak: u32,
};

io: std.Io,
lineage_id: u64,
schedule: Schedule = .{},
limits: Limits,
remaining: Charge,
depth_peak: u32 = 0,
mutex: std.Io.Mutex = .init,
terminal: std.atomic.Value(bool) = .init(false),
first_report: Report,

pub fn init(io: std.Io, lineage_id: u64, limits: Limits) Budget {
    var available: Charge = .{};
    inline for (@typeInfo(Charge).@"struct".field_names) |name| {
        @field(available, name) = @field(limits, name);
    }
    return .{
        .io = io,
        .lineage_id = lineage_id,
        .limits = limits,
        .remaining = available,
        // SAFETY: failLocked initializes the report before publishing terminal.
        .first_report = undefined,
    };
}

pub fn isExhausted(self: *const Budget) bool {
    return self.terminal.load(.acquire);
}

pub fn report(self: *const Budget) ?Report {
    if (!self.isExhausted()) return null;
    // The release store publishes this immutable first report.
    return self.first_report;
}

pub fn snapshot(self: *Budget) Snapshot {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return .{
        .consumed = self.consumedLocked(),
        .available = self.remaining,
        .depth_peak = self.depth_peak,
    };
}

fn isWorkOnly(amount: Charge) bool {
    return amount.bytes == 0 and
        amount.objects == 0 and
        amount.nodes == 0 and
        amount.output == 0 and
        amount.processes == 0 and
        amount.paths == 0;
}

pub fn charge(self: *Budget, amount: Charge, backend: Backend) Error!void {
    if (isWorkOnly(amount)) return self.chargeWorkWithLease(null, amount.work, backend);
    return self.chargeWithLease(null, amount, backend);
}

pub fn chargeWork(self: *Budget, count: u64, unit_cost: u64, backend: Backend) Error!void {
    const product = @mulWithOverflow(count, unit_cost);
    if (product[1] != 0) return self.overflow(.work, backend);
    return self.chargeWorkWithLease(null, product[0], backend);
}

fn chargeRegvmInstruction(self: *Budget, lease: *Lease) Error!void {
    if (self.isExhausted()) return error.Exhausted;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.chargeRegvmInstructionLocked(lease);
}

fn chargeRegvmInstructionLocked(self: *Budget, lease: *Lease) Error!void {
    return self.chargeWorkWithLeaseLocked(lease, 1, .regvm);
}

fn chargeWorkWithLease(self: *Budget, lease: ?*Lease, work: u64, backend: Backend) Error!void {
    if (self.isExhausted()) return error.Exhausted;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.chargeWorkWithLeaseLocked(lease, work, backend);
}

fn chargeWorkWithLeaseLocked(self: *Budget, lease: ?*Lease, work: u64, backend: Backend) Error!void {
    if (self.isExhausted()) return error.Exhausted;
    if (work > self.remaining.work) {
        return self.failLocked(.work, .quota, self.limits.work, self.remaining.work, work, backend);
    }
    if (lease) |leaf| {
        if (leaf.parent == null) {
            std.debug.assert(leaf.budget == self);
            std.debug.assert(leaf.ancestry_depth == 1);
            if (work > leaf.remaining_work) {
                return self.failLocked(.work, .lease, leaf.work_limit, leaf.remaining_work, work, backend);
            }
            self.remaining.work -= work;
            leaf.remaining_work -= work;
            return;
        }
        try self.checkLeaseLocked(leaf, work, backend);
        self.remaining.work -= work;
        var cursor: ?*Lease = leaf;
        for (0..leaf.ancestry_depth) |_| {
            std.debug.assert(cursor != null);
            const current = cursor.?;
            current.remaining_work -= work;
            cursor = current.parent;
        }
        std.debug.assert(cursor == null);
        return;
    }
    self.remaining.work -= work;
}

pub fn overflow(self: *Budget, comptime resource: Resource, backend: Backend) Error {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (comptime resource == .depth) {
        return self.failLocked(.depth, .overflow, self.limits.depth, self.limits.depth, null, backend);
    }
    if (comptime resource == .retained_bytes) {
        return self.failLocked(
            .retained_bytes,
            .overflow,
            std.math.maxInt(u64),
            std.math.maxInt(u64),
            null,
            backend,
        );
    }
    const name = @tagName(resource);
    const available: u64 = @field(self.remaining, name);
    return self.failLocked(resource, .overflow, @field(self.limits, name), available, null, backend);
}

/// Freeze this lineage on a retained-storage limit failure.
///
/// Retained storage is owned by a Store rather than an evaluation budget, so
/// it has no `Limits` or `remaining` field. The report still uses the active
/// lineage's immutable first-report protocol.
pub fn failRetained(
    self: *Budget,
    limit: u64,
    available: u64,
    requested: u64,
    backend: Backend,
) Error {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.failLocked(.retained_bytes, .quota, limit, available, requested, backend);
}

/// Undo provisional byte/object claims after a real allocator failure.
///
/// Work is intentionally not restored: attempting the allocation consumed
/// cumulative evaluation work even when the host allocator returned null.
pub fn cancelAllocation(self: *Budget, bytes: u64, objects: u64) void {
    if (bytes == 0 and objects == 0) return;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const consumed = self.consumedLocked();
    std.debug.assert(bytes <= consumed.bytes);
    std.debug.assert(objects <= consumed.objects);
    self.remaining.bytes += bytes;
    self.remaining.objects += objects;
}

pub fn checkDepth(self: *Budget, depth: u32, backend: Backend) Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.checkDepthLocked(depth, backend);
}

fn checkDepthLocked(self: *Budget, depth: u32, backend: Backend) Error!void {
    if (self.isExhausted()) return error.Exhausted;
    if (depth > self.limits.depth) {
        return self.failLocked(.depth, .quota, self.limits.depth, self.limits.depth, depth, backend);
    }
    self.depth_peak = @max(self.depth_peak, depth);
}

fn chargeWithLease(self: *Budget, lease: ?*Lease, amount: Charge, backend: Backend) Error!void {
    if (self.isExhausted()) return error.Exhausted;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.isExhausted()) return error.Exhausted;
    inline for (@typeInfo(Charge).@"struct".field_names) |name| {
        const wanted = @field(amount, name);
        const available = @field(self.remaining, name);
        if (wanted > available) {
            return self.failLocked(
                @field(Resource, name),
                .quota,
                @field(self.limits, name),
                available,
                wanted,
                backend,
            );
        }
    }
    if (lease) |leaf| try self.checkLeaseLocked(leaf, amount.work, backend);
    inline for (@typeInfo(Charge).@"struct".field_names) |name| {
        @field(self.remaining, name) -= @field(amount, name);
    }
    if (lease) |leaf| {
        var cursor: ?*Lease = leaf;
        for (0..leaf.ancestry_depth) |_| {
            std.debug.assert(cursor != null);
            const current = cursor.?;
            current.remaining_work -= amount.work;
            cursor = current.parent;
        }
        std.debug.assert(cursor == null);
    }
}

fn checkLeaseLocked(self: *Budget, leaf: *Lease, work: u64, backend: Backend) Error!void {
    var cursor: ?*Lease = leaf;
    for (0..leaf.ancestry_depth) |_| {
        std.debug.assert(cursor != null);
        const current = cursor.?;
        std.debug.assert(current.budget == self);
        if (work > current.remaining_work) {
            return self.failLocked(.work, .lease, current.work_limit, current.remaining_work, work, backend);
        }
        cursor = current.parent;
    }
    std.debug.assert(cursor == null);
}

fn consumedLocked(self: *const Budget) Charge {
    var used: Charge = .{};
    inline for (@typeInfo(Charge).@"struct".field_names) |name| {
        @field(used, name) = @field(self.limits, name) - @field(self.remaining, name);
    }
    return used;
}

fn failLocked(
    self: *Budget,
    resource: Resource,
    reason: Reason,
    limit: u64,
    available: u64,
    requested: ?u64,
    backend: Backend,
) Error {
    if (self.isExhausted()) return error.Exhausted;
    self.first_report = .{
        .lineage_id = self.lineage_id,
        .schedule = self.schedule,
        .backend = backend,
        .resource = resource,
        .reason = reason,
        .limit = limit,
        .available = available,
        .requested = requested,
        .consumed = self.consumedLocked(),
        .depth_peak = self.depth_peak,
    };
    self.terminal.store(true, .release);
    return error.Exhausted;
}

/// Caller-owned, address-stable leases share their ancestor allowances.
/// Exhaustion of any lease terminates its entire lineage.
pub const Lease = struct {
    budget: *Budget,
    parent: ?*Lease = null,
    work_limit: u64,
    remaining_work: u64,
    ancestry_depth: u32,

    /// Trusted host entry only. Restricted contexts can create children, not roots.
    pub fn root(budget: *Budget, work_limit: u64) Error!Lease {
        budget.mutex.lockUncancelable(budget.io);
        defer budget.mutex.unlock(budget.io);
        try budget.checkDepthLocked(1, .scheduler);
        const allowance = @min(work_limit, budget.remaining.work);
        return .{
            .budget = budget,
            .work_limit = allowance,
            .remaining_work = allowance,
            .ancestry_depth = 1,
        };
    }

    pub fn child(self: *Lease, work_limit: u64) Error!Lease {
        const budget = self.budget;
        budget.mutex.lockUncancelable(budget.io);
        defer budget.mutex.unlock(budget.io);
        const depth = std.math.add(u32, self.ancestry_depth, 1) catch
            return budget.failLocked(.depth, .overflow, budget.limits.depth, 0, null, .scheduler);
        try budget.checkDepthLocked(depth, .scheduler);
        const allowance = @min(work_limit, @min(self.remaining_work, budget.remaining.work));
        return .{
            .budget = budget,
            .parent = self,
            .work_limit = allowance,
            .remaining_work = allowance,
            .ancestry_depth = depth,
        };
    }

    pub fn charge(self: *Lease, amount: Charge, backend: Backend) Error!void {
        if (isWorkOnly(amount)) return self.budget.chargeWorkWithLease(self, amount.work, backend);
        return self.budget.chargeWithLease(self, amount, backend);
    }

    pub fn chargeWork(self: *Lease, count: u64, unit_cost: u64, backend: Backend) Error!void {
        const product = @mulWithOverflow(count, unit_cost);
        if (product[1] != 0) return self.budget.overflow(.work, backend);
        return self.budget.chargeWorkWithLease(self, product[0], backend);
    }

    pub fn chargeRegvmInstruction(self: *Lease) Error!void {
        return self.budget.chargeRegvmInstruction(self);
    }

    pub fn chargeSequentialWork(self: *Lease, amounts: []const u64, backend: Backend) Error!void {
        if (amounts.len == 0) return;
        const budget = self.budget;
        if (budget.isExhausted()) return error.Exhausted;
        budget.mutex.lockUncancelable(budget.io);
        defer budget.mutex.unlock(budget.io);
        for (amounts) |work| {
            try budget.chargeWorkWithLeaseLocked(self, work, backend);
        }
    }

    /// Hold the lineage lock across verified, VM-local operations. Never call
    /// an intrinsic, allocator, host callback, or blocking operation inside it.
    pub const RegvmWindow = struct {
        lease: *Lease,
        available: u64,
        pending: u64 = 0,
        // At most 128 successful debit steps keep the lineage lock held.
        steps_left: u8 = 128,

        pub inline fn charge(self: *RegvmWindow) Error!void {
            if (self.steps_left == 0 or self.available == 0) {
                return self.chargeWork(1);
            }
            self.steps_left -= 1;
            self.available -= 1;
            self.pending += 1;
        }

        pub fn chargeWork(self: *RegvmWindow, work: u64) Error!void {
            if (self.steps_left == 0) self.renew();
            self.steps_left -= 1;
            if (work > self.available or self.available == 0) {
                self.flush();
                return self.lease.budget.chargeWorkWithLeaseLocked(self.lease, work, .regvm);
            }
            self.available -= work;
            self.pending += work;
        }

        /// Keep the per-namespace traversal and access debits consecutive.
        pub fn chargeNamespaceAccess(self: *RegvmWindow, work: u64) Error!void {
            if (self.steps_left < 2) self.renew();
            try self.charge();
            try self.chargeWork(work);
        }

        // Release the lineage lock after a bounded number of VM-local steps.
        // Reopening observes sibling debits before reserving more work.
        fn renew(self: *RegvmWindow) void {
            const lease = self.lease;
            self.flush();
            lease.budget.mutex.unlock(lease.budget.io);
            self.* = lease.lockRegvm();
        }
        fn flush(self: *RegvmWindow) void {
            if (self.pending == 0) return;
            const budget = self.lease.budget;
            budget.remaining.work -= self.pending;
            if (self.lease.parent == null) {
                std.debug.assert(self.lease.ancestry_depth == 1);
                self.lease.remaining_work -= self.pending;
                self.pending = 0;
                return;
            }
            var cursor: ?*Lease = self.lease;
            for (0..self.lease.ancestry_depth) |_| {
                std.debug.assert(cursor != null);
                const current = cursor.?;
                current.remaining_work -= self.pending;
                cursor = current.parent;
            }
            std.debug.assert(cursor == null);
            self.pending = 0;
        }

        pub fn deinit(self: *RegvmWindow) void {
            const budget = self.lease.budget;
            self.flush();
            self.* = undefined;
            budget.mutex.unlock(budget.io);
        }

        pub fn deinitAndCharge(self: *RegvmWindow) Error!void {
            const budget = self.lease.budget;
            defer budget.mutex.unlock(budget.io);
            self.flush();
            const lease = self.lease;
            self.* = undefined;
            return budget.chargeRegvmInstructionLocked(lease);
        }
    };

    pub fn lockRegvm(self: *Lease) RegvmWindow {
        const budget = self.budget;
        budget.mutex.lockUncancelable(budget.io);
        var available = if (budget.isExhausted()) @as(u64, 0) else budget.remaining.work;
        if (self.parent == null) {
            std.debug.assert(self.ancestry_depth == 1);
            available = @min(available, self.remaining_work);
            return .{ .lease = self, .available = available };
        }
        var cursor: ?*Lease = self;
        for (0..self.ancestry_depth) |_| {
            std.debug.assert(cursor != null);
            available = @min(available, cursor.?.remaining_work);
            cursor = cursor.?.parent;
        }
        std.debug.assert(cursor == null);
        return .{ .lease = self, .available = available };
    }
};

/// Cumulative allocation accounting; freeing memory never restores quota.
/// The adapter and its lease must outlive every allocator handle derived from it.
pub const AccountAllocator = struct {
    base: std.mem.Allocator,
    lease: *Lease,
    backend: Backend,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    const Reservation = struct {
        account: *AccountAllocator,
        bytes: u64,
        objects: u64,

        /// Failed host allocations release provisional storage, not attempted work.
        fn cancel(self: Reservation) void {
            self.account.lease.budget.cancelAllocation(self.bytes, self.objects);
        }
    };

    pub fn init(base: std.mem.Allocator, lease: *Lease, backend: Backend) AccountAllocator {
        std.debug.assert(base.vtable != &vtable);
        return .{ .base = base, .lease = lease, .backend = backend };
    }

    pub fn allocator(self: *AccountAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn reserve(self: *AccountAllocator, bytes: usize, objects: u64) ?Reservation {
        self.lease.charge(.{
            .work = 1 + @as(u64, @intCast(bytes / 64)),
            .bytes = @intCast(bytes),
            .objects = objects,
        }, self.backend) catch return null;
        return .{ .account = self, .bytes = @intCast(bytes), .objects = objects };
    }

    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *AccountAllocator = @ptrCast(@alignCast(raw));
        const reservation = self.reserve(len, 1) orelse return null;
        return self.base.rawAlloc(len, alignment, return_address) orelse {
            reservation.cancel();
            return null;
        };
    }

    fn resize(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *AccountAllocator = @ptrCast(@alignCast(raw));
        const growth = new_len -| memory.len;
        const reservation = self.reserve(growth, 0) orelse return false;
        if (self.base.rawResize(memory, alignment, new_len, return_address)) return true;
        reservation.cancel();
        return false;
    }

    fn remap(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *AccountAllocator = @ptrCast(@alignCast(raw));
        // A remap can allocate a complete replacement before releasing the old one.
        const reservation = self.reserve(new_len, 1) orelse return null;
        return self.base.rawRemap(memory, alignment, new_len, return_address) orelse {
            reservation.cancel();
            return null;
        };
    }

    fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *AccountAllocator = @ptrCast(@alignCast(raw));
        self.base.rawFree(memory, alignment, return_address);
    }
};

test "budget exhaustion is terminal and preserves the first report" {
    var budget = Budget.init(std.testing.io, 7, .{ .work = 3 });
    try budget.charge(.{ .work = 3 }, .regvm);
    try std.testing.expectError(error.Exhausted, budget.charge(.{ .work = 1 }, .native));
    const first = (budget.report() orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(Resource.work, first.resource);
    try std.testing.expectEqual(@as(u64, 3), first.consumed.work);
    try std.testing.expectError(error.Exhausted, budget.charge(.{}, .reader));
    try std.testing.expectEqualDeep(first, (budget.report() orelse return error.TestUnexpectedResult));
}

test "quota refusal cannot debit a successful component of the same charge" {
    var budget = Budget.init(std.testing.io, 8, .{ .work = 100, .bytes = 8 });
    try budget.charge(.{ .work = 2, .bytes = 8 }, .native);
    try std.testing.expectError(error.Exhausted, budget.charge(.{ .work = 20, .bytes = 1 }, .native));
    const failure = (budget.report() orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(Resource.bytes, failure.resource);
    try std.testing.expectEqual(@as(u64, 2), failure.consumed.work);
    try std.testing.expectEqual(@as(u64, 8), failure.consumed.bytes);
}

test "child and sibling work debit every ancestor lease" {
    var budget = Budget.init(std.testing.io, 9, .{ .work = 1000 });
    var parent = try Lease.root(&budget, 30);
    var left = try parent.child(30);
    var right = try parent.child(30);
    var grandchild = try left.child(30);
    try grandchild.charge(.{ .work = 20 }, .regvm);
    try std.testing.expectError(error.Exhausted, right.charge(.{ .work = 11 }, .regvm));
    const failure = (budget.report() orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(u64, 20), failure.consumed.work);
    try std.testing.expectEqual(@as(u64, 10), failure.available);
    try std.testing.expectEqual(Reason.lease, failure.reason);
    try std.testing.expectError(error.Exhausted, parent.charge(.{}, .scheduler));
}

test "instruction charges debit shared ancestors and report the first lease failure" {
    var budget = Budget.init(std.testing.io, 19, .{ .work = 4 });
    var parent = try Lease.root(&budget, 2);
    var left = try parent.child(2);
    var right = try parent.child(2);
    try left.chargeRegvmInstruction();
    try left.chargeRegvmInstruction();
    try std.testing.expectEqual(@as(u64, 0), parent.remaining_work);
    try std.testing.expectError(error.Exhausted, right.chargeRegvmInstruction());
    const failure = budget.report() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Backend.regvm, failure.backend);
    try std.testing.expectEqual(Reason.lease, failure.reason);
    try std.testing.expectEqual(@as(u64, 2), failure.consumed.work);
    try std.testing.expectEqual(@as(u64, 0), failure.available);
    try std.testing.expectEqual(@as(?u64, 1), failure.requested);
    try std.testing.expectEqual(@as(u64, 2), right.remaining_work);
    try std.testing.expectError(error.Exhausted, left.chargeRegvmInstruction());
    try std.testing.expectEqualDeep(failure, budget.report().?);
}

test "instruction charges exhaust global work before the lease and preserve other resources" {
    var budget = Budget.init(std.testing.io, 20, .{ .work = 2, .bytes = 4 });
    var parent = try Lease.root(&budget, 2);
    try parent.charge(.{ .bytes = 1 }, .native);
    try parent.chargeRegvmInstruction();
    try parent.chargeRegvmInstruction();
    try std.testing.expectError(error.Exhausted, parent.chargeRegvmInstruction());
    const failure = budget.report() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Backend.regvm, failure.backend);
    try std.testing.expectEqual(Reason.quota, failure.reason);
    try std.testing.expectEqual(@as(u64, 0), failure.available);
    try std.testing.expectEqual(@as(?u64, 1), failure.requested);
    try std.testing.expectEqual(@as(u64, 2), failure.consumed.work);
    try std.testing.expectEqual(@as(u64, 1), failure.consumed.bytes);
    try std.testing.expectEqual(@as(u64, 0), parent.remaining_work);
}

test "scoped VM charges enforce the first shared refusal and release the lock" {
    var budget = Budget.init(std.testing.io, 23, .{ .work = 3 });
    var root = try Lease.root(&budget, 2);
    {
        var window = root.lockRegvm();
        defer window.deinit();
        try window.charge();
        try window.charge();
        try std.testing.expectError(error.Exhausted, window.charge());
    }
    try std.testing.expectEqual(@as(u64, 2), budget.snapshot().consumed.work);
    try std.testing.expectEqual(@as(u64, 0), root.remaining_work);
    const failure = budget.report() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Reason.lease, failure.reason);
    try std.testing.expectEqual(@as(u64, 2), failure.consumed.work);
    try std.testing.expectError(error.Exhausted, root.chargeRegvmInstruction());
    try std.testing.expectEqualDeep(failure, budget.report().?);
}

test "scoped VM charges commit partial child work before another lineage charge" {
    var budget = Budget.init(std.testing.io, 24, .{ .work = 10 });
    var parent = try Lease.root(&budget, 8);
    var child = try parent.child(5);
    {
        var window = child.lockRegvm();
        defer window.deinit();
        try window.charge();
        try window.charge();
        try window.charge();
    }
    try std.testing.expectEqual(@as(u64, 3), budget.snapshot().consumed.work);
    try std.testing.expectEqual(@as(u64, 5), parent.remaining_work);
    try std.testing.expectEqual(@as(u64, 2), child.remaining_work);
    try parent.chargeWork(2, 1, .native);
    try child.chargeRegvmInstruction();
    try child.chargeRegvmInstruction();
    try std.testing.expectEqual(@as(u64, 7), budget.snapshot().consumed.work);
    try std.testing.expectError(error.Exhausted, child.chargeRegvmInstruction());
    const failure = budget.report() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Reason.lease, failure.reason);
    try std.testing.expectEqual(@as(u64, 7), failure.consumed.work);
}

test "concurrent instruction charges cannot overspend sibling leases" {
    var budget = Budget.init(std.testing.io, 21, .{ .work = 2_000 });
    var parent = try Lease.root(&budget, 1_000);
    var children: [8]Lease = undefined;
    for (0..children.len) |index| {
        children[index] = try parent.child(1_000);
    }
    var successes: std.atomic.Value(u32) = .init(0);
    const Worker = struct {
        fn run(shared: *Lease, count: *std.atomic.Value(u32)) void {
            for (0..256) |_| {
                shared.chargeRegvmInstruction() catch return;
                std.debug.assert(count.fetchAdd(1, .monotonic) < 1_000);
            }
        }
    };
    var group: std.Io.Group = .init;
    defer group.cancel(std.testing.io);
    for (&children) |*child| {
        group.concurrent(std.testing.io, Worker.run, .{ child, &successes }) catch
            return error.SkipZigTest;
    }
    try group.await(std.testing.io);
    try std.testing.expectEqual(@as(u32, 1_000), successes.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), parent.remaining_work);
    try std.testing.expectEqual(@as(u64, 1_000), budget.remaining.work);
    const failure = budget.report() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Backend.regvm, failure.backend);
    try std.testing.expectEqual(Reason.lease, failure.reason);
    try std.testing.expectEqual(@as(u64, 1_000), failure.consumed.work);
    try std.testing.expectEqual(@as(u64, 0), failure.available);
    try std.testing.expectEqual(@as(?u64, 1), failure.requested);
}

test "resource product overflow fails instead of minting work" {
    var budget = Budget.init(std.testing.io, 10, .{ .work = std.math.maxInt(u64) });
    try std.testing.expectError(error.Exhausted, budget.chargeWork(std.math.maxInt(u64), 2, .transform));
    const failure = (budget.report() orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(Reason.overflow, failure.reason);
    try std.testing.expectEqual(@as(?u64, null), failure.requested);
    try std.testing.expectEqual(@as(u64, 0), failure.consumed.work);
}

test "depth tracks a peak without refueling cumulative work" {
    var budget = Budget.init(std.testing.io, 11, .{ .work = 5, .depth = 3 });
    try budget.checkDepth(3, .reader);
    try budget.charge(.{ .work = 2 }, .reader);
    try budget.checkDepth(1, .reader);
    try budget.charge(.{ .work = 3 }, .reader);
    try std.testing.expectError(error.Exhausted, budget.checkDepth(4, .reader));
    const failure = (budget.report() orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(Resource.depth, failure.resource);
    try std.testing.expectEqual(@as(u32, 3), failure.depth_peak);
    try std.testing.expectEqual(@as(u64, 5), failure.consumed.work);
}

test "lease ancestry cannot exceed the shared depth quota" {
    var budget = Budget.init(std.testing.io, 12, .{ .work = 100, .depth = 2 });
    var parent = try Lease.root(&budget, 100);
    var child = try parent.child(100);
    try std.testing.expectError(error.Exhausted, child.child(100));
    try std.testing.expectEqual(Resource.depth, (budget.report() orelse return error.TestUnexpectedResult).resource);
}

test "concurrent charges cannot overspend a shared lineage" {
    var budget = Budget.init(std.testing.io, 13, .{ .work = 1000, .bytes = 2000 });
    var successes: std.atomic.Value(u32) = .init(0);
    const Worker = struct {
        fn run(shared: *Budget, count: *std.atomic.Value(u32)) void {
            for (0..256) |_| {
                shared.charge(.{ .work = 1, .bytes = 2 }, .native) catch return;
                std.debug.assert(count.fetchAdd(1, .monotonic) < 1000);
            }
        }
    };
    var group: std.Io.Group = .init;
    defer group.cancel(std.testing.io);
    for (0..8) |_| {
        group.concurrent(std.testing.io, Worker.run, .{ &budget, &successes }) catch
            return error.SkipZigTest;
    }
    try group.await(std.testing.io);
    try std.testing.expectEqual(@as(u32, 1000), successes.load(.monotonic));
    const failure = (budget.report() orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(u64, 1000), failure.consumed.work);
    try std.testing.expectEqual(@as(u64, 2000), failure.consumed.bytes);
}

test "accounted allocator never refunds freed allocations" {
    var budget = Budget.init(std.testing.io, 14, .{ .work = 100, .bytes = 8 });
    var lease = try Lease.root(&budget, 100);
    var account = AccountAllocator.init(std.testing.allocator, &lease, .transform);
    const alloc = account.allocator();
    const memory = try alloc.alloc(u8, 8);
    alloc.free(memory);
    try std.testing.expectError(error.OutOfMemory, alloc.alloc(u8, 1));
    try std.testing.expectEqual(Resource.bytes, (budget.report() orelse return error.TestUnexpectedResult).resource);
    try std.testing.expectEqual(@as(u64, 8), (budget.report() orelse return error.TestUnexpectedResult).consumed.bytes);
}

test "accounted allocator cancels only unsuccessful allocation reservations" {
    var storage: [8]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var budget = Budget.init(std.testing.io, 15, .{ .work = 100, .bytes = 32 });
    var lease = try Lease.root(&budget, 100);
    var account = AccountAllocator.init(fixed.allocator(), &lease, .binder);
    const alloc = account.allocator();
    const memory = try alloc.alloc(u8, 8);
    defer alloc.free(memory);
    try std.testing.expect(!alloc.resize(memory, 16));
    try std.testing.expectError(error.OutOfMemory, alloc.alloc(u8, 1));
    const state = budget.snapshot();
    try std.testing.expectEqual(@as(u64, 8), state.consumed.bytes);
    try std.testing.expectEqual(@as(u64, 1), state.consumed.objects);
    try std.testing.expect(state.consumed.work > 1);
    try std.testing.expect(!budget.isExhausted());
}

test "accounted allocator debits child and ancestor work before allocation" {
    var budget = Budget.init(std.testing.io, 16, .{ .work = 100, .bytes = 100 });
    var parent = try Lease.root(&budget, 100);
    var child = try parent.child(1);
    var account = AccountAllocator.init(std.testing.allocator, &child, .code);
    const alloc = account.allocator();
    const memory = try alloc.alloc(u8, 1);
    defer alloc.free(memory);
    try std.testing.expectError(error.OutOfMemory, alloc.alloc(u8, 1));
    try std.testing.expectEqual(Reason.lease, (budget.report() orelse return error.TestUnexpectedResult).reason);
    try std.testing.expectEqual(@as(u64, 1), (budget.report() orelse return error.TestUnexpectedResult).consumed.work);
    try std.testing.expectEqual(@as(u64, 99), parent.remaining_work);
}

test "external retained exhaustion freezes the first lineage report" {
    var budget = Budget.init(std.testing.io, 17, .{ .work = 10 });
    try budget.charge(.{ .work = 2 }, .native);
    try std.testing.expectEqual(
        error.Exhausted,
        budget.failRetained(16, 4, 13, .code),
    );
    const first = (budget.report() orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(Resource.retained_bytes, first.resource);
    try std.testing.expectEqual(Reason.quota, first.reason);
    try std.testing.expectEqual(@as(u64, 16), first.limit);
    try std.testing.expectEqual(@as(u64, 4), first.available);
    try std.testing.expectEqual(@as(?u64, 13), first.requested);
    try std.testing.expectEqual(@as(u64, 2), first.consumed.work);
    try std.testing.expectEqual(
        error.Exhausted,
        budget.failRetained(32, 0, 33, .scheduler),
    );
    try std.testing.expectEqualDeep(first, (budget.report() orelse return error.TestUnexpectedResult));
}

test "allocation cancellation restores bytes and objects but not attempted work" {
    var budget = Budget.init(std.testing.io, 18, .{
        .work = 10,
        .bytes = 8,
        .objects = 1,
    });
    try budget.charge(.{
        .work = 3,
        .bytes = 8,
        .objects = 1,
    }, .native);
    budget.cancelAllocation(8, 1);
    const state = budget.snapshot();
    try std.testing.expectEqual(@as(u64, 3), state.consumed.work);
    try std.testing.expectEqual(@as(u64, 0), state.consumed.bytes);
    try std.testing.expectEqual(@as(u64, 0), state.consumed.objects);
}

test "scoped VM charges can deinit and charge instruction under held lock" {
    var budget = Budget.init(std.testing.io, 25, .{ .work = 10 });
    var root = try Lease.root(&budget, 3);
    {
        var window = root.lockRegvm();
        try window.charge();
        try window.charge();
        try window.deinitAndCharge();
    }
    try std.testing.expectEqual(@as(u64, 3), budget.snapshot().consumed.work);
    try std.testing.expectEqual(@as(u64, 0), root.remaining_work);
    try std.testing.expectError(error.Exhausted, root.chargeRegvmInstruction());
    const failure = budget.report() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Reason.lease, failure.reason);
    try std.testing.expectEqual(@as(u64, 3), failure.consumed.work);
}

test "sequential work charges preserve exact first failure ordering" {
    var budget = Budget.init(std.testing.io, 26, .{ .work = 10 });
    var root = try Lease.root(&budget, 5);
    try root.chargeSequentialWork(&.{ 1, 2 }, .regvm);
    try std.testing.expectEqual(@as(u64, 3), budget.snapshot().consumed.work);
    try std.testing.expectEqual(@as(u64, 2), root.remaining_work);

    try std.testing.expectError(error.Exhausted, root.chargeSequentialWork(&.{ 1, 5 }, .regvm));
    const failure = budget.report() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Reason.lease, failure.reason);
    try std.testing.expectEqual(@as(u64, 4), failure.consumed.work);
    try std.testing.expectEqual(@as(u64, 1), failure.available);
    try std.testing.expectEqual(@as(?u64, 5), failure.requested);
}

test "window namespace work reports the exact first lease refusal" {
    var budget = Budget.init(std.testing.io, 27, .{ .work = 20 });
    var parent = try Lease.root(&budget, 7);
    var child = try parent.child(7);
    {
        var window = child.lockRegvm();
        defer window.deinit();
        try window.charge();
        try window.chargeWork(3);
        try std.testing.expectError(error.Exhausted, window.chargeWork(5));
    }
    const failure = budget.report() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Backend.regvm, failure.backend);
    try std.testing.expectEqual(Reason.lease, failure.reason);
    try std.testing.expectEqual(@as(u64, 7), failure.limit);
    try std.testing.expectEqual(@as(u64, 3), failure.available);
    try std.testing.expectEqual(@as(?u64, 5), failure.requested);
    try std.testing.expectEqual(@as(u64, 4), failure.consumed.work);
    try std.testing.expectEqual(@as(u64, 3), parent.remaining_work);
    try std.testing.expectEqual(@as(u64, 3), child.remaining_work);
}

test "window namespace work reports quota before a larger lease allowance" {
    var budget = Budget.init(std.testing.io, 28, .{ .work = 3 });
    var root = try Lease.root(&budget, 10);
    {
        var window = root.lockRegvm();
        defer window.deinit();
        try window.charge();
        try window.chargeWork(2);
        try std.testing.expectError(error.Exhausted, window.chargeWork(8));
    }
    const failure = budget.report() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Reason.quota, failure.reason);
    try std.testing.expectEqual(@as(u64, 0), failure.available);
    try std.testing.expectEqual(@as(?u64, 8), failure.requested);
    try std.testing.expectEqual(@as(u64, 3), failure.consumed.work);
}

test "renewed VM windows retain exact cumulative failure reports" {
    var budget = Budget.init(std.testing.io, 29, .{ .work = 140 });
    var root = try Lease.root(&budget, 140);
    {
        var window = root.lockRegvm();
        defer window.deinit();
        for (0..128) |_| try window.charge();
        try window.chargeWork(12);
        try std.testing.expectError(error.Exhausted, window.charge());
    }
    const failure = budget.report() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Reason.quota, failure.reason);
    try std.testing.expectEqual(@as(u64, 140), failure.consumed.work);
    try std.testing.expectEqual(@as(u64, 0), failure.available);
    try std.testing.expectEqual(@as(?u64, 1), failure.requested);
    try std.testing.expectEqual(@as(u64, 0), root.remaining_work);
}

test "namespace debit pair reports its access failure across window renewal" {
    var budget = Budget.init(std.testing.io, 30, .{ .work = 131 });
    var root = try Lease.root(&budget, 131);
    {
        var window = root.lockRegvm();
        defer window.deinit();
        for (0..127) |_| try window.charge();
        try std.testing.expectError(error.Exhausted, window.chargeNamespaceAccess(5));
    }
    const failure = budget.report() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Reason.quota, failure.reason);
    try std.testing.expectEqual(@as(u64, 128), failure.consumed.work);
    try std.testing.expectEqual(@as(u64, 3), failure.available);
    try std.testing.expectEqual(@as(?u64, 5), failure.requested);
}
