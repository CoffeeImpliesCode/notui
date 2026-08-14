const std = @import("std");

const skript = @import("../root.zig");
const Runtime = skript.Runtime;

const intrin = @import("root.zig");
const makeWrapper = intrin.makeWrapper;

fn andImpl(a: bool, b: bool) bool {
    return a and b;
}

fn orImpl(a: bool, b: bool) bool {
    return a or b;
}

fn notImpl(a: bool) bool {
    return (!a);
}

pub const boolean_and = makeWrapper(andImpl);
pub const boolean_or = makeWrapper(orImpl);
pub const boolean_not = makeWrapper(notImpl);

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
    }
}

// ---- bool functional tests ---- //

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

fn initTestingRuntime() !*Runtime {
    return Runtime.init(std.testing.allocator, std.testing.io);
}

test "bool operations" {
    const runtime = try initTestingRuntime();
    defer runtime.deinit();

    try expect((try boolean_and(runtime.context(), .nil, .nil, &.{ .true, .true })).obj.toBool());
    try expect(!(try boolean_and(runtime.context(), .nil, .nil, &.{ .true, .false })).obj.toBool());
    try expect(!(try boolean_and(runtime.context(), .nil, .nil, &.{ .false, .true })).obj.toBool());
    try expect(!(try boolean_and(runtime.context(), .nil, .nil, &.{ .false, .false })).obj.toBool());

    try expect((try boolean_or(runtime.context(), .nil, .nil, &.{ .true, .true })).obj.toBool());
    try expect((try boolean_or(runtime.context(), .nil, .nil, &.{ .true, .false })).obj.toBool());
    try expect((try boolean_or(runtime.context(), .nil, .nil, &.{ .false, .true })).obj.toBool());
    try expect(!(try boolean_or(runtime.context(), .nil, .nil, &.{ .false, .false })).obj.toBool());

    try expect(!(try boolean_not(runtime.context(), .nil, .nil, &.{.true})).obj.toBool());
    try expect((try boolean_not(runtime.context(), .nil, .nil, &.{.false})).obj.toBool());

    // return type
    try expectEqual(
        skript.builtins.type_bool,
        (try boolean_and(runtime.context(), .nil, .nil, &.{ .true, .true })).typ,
    );
    try expectEqual(
        skript.builtins.type_bool,
        (try boolean_or(runtime.context(), .nil, .nil, &.{ .true, .false })).typ,
    );
    try expectEqual(skript.builtins.type_bool, (try boolean_not(runtime.context(), .nil, .nil, &.{.true})).typ);

    // arity errors
    try expectError(error.ArityMismatch, boolean_and(runtime.context(), .nil, .nil, &.{}));
    try expectError(error.ArityMismatch, boolean_and(runtime.context(), .nil, .nil, &.{.true}));
    try expectError(error.ArityMismatch, boolean_and(runtime.context(), .nil, .nil, &.{ .true, .true, .false }));
    try expectError(error.ArityMismatch, boolean_or(runtime.context(), .nil, .nil, &.{}));
    try expectError(error.ArityMismatch, boolean_not(runtime.context(), .nil, .nil, &.{}));
    try expectError(error.ArityMismatch, boolean_not(runtime.context(), .nil, .nil, &.{ .true, .false }));
}
