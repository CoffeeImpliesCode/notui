//! Stub dynamic library module for platforms without dlopen.
//! All functions log and return `error.Unsupported`.

const std = @import("std");
const log = std.log.scoped(.dynlib);

const skript = @import("../root.zig");
const Error = skript.Error;
const Value = skript.Value;
const EvalContext = skript.EvalContext;

pub fn open(_: *EvalContext, _: Value, _: Value, _: []const Value) Error!Value {
    log.err("dynamic-library:open: not supported on this platform", .{});
    return error.Unsupported;
}

pub fn close(_: *EvalContext, _: Value, _: Value, _: []const Value) Error!Value {
    log.err("dynamic-library:close: not supported on this platform", .{});
    return error.Unsupported;
}

pub fn lookup(_: *EvalContext, _: Value, _: Value, _: []const Value) Error!Value {
    log.err("dynamic-library:lookup: not supported on this platform", .{});
    return error.Unsupported;
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
    }
}
