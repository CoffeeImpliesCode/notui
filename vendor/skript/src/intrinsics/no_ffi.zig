//! Stub FFI module for platforms that do not support libffi.
//! All functions log and return `error.Unsupported`.

const std = @import("std");
const log = std.log.scoped(.ffi);

const skript = @import("../root.zig");
const Value = skript.Value;
const Error = skript.Error;
const EvalContext = skript.EvalContext;

/// Placeholder — FFI is unavailable. Holds only the function pointer.
/// no libffi cif or type metadata is allocated.
pub const Function = struct {
    ret: Value,
    ptr: *const fn () callconv(.c) void,
};
/// Stub: always logs and returns `error.Unsupported`.
pub fn makeFunc(_: *EvalContext, _: Value, _: Value, _: []const Value) Error!Value {
    log.err("ffi:make-func: not supported on this platform", .{});
    return error.Unsupported;
}

/// Stub: always logs and returns `error.Unsupported`.
pub fn invoke(_: *EvalContext, _: Value, _: []const Value) Error!Value {
    log.err("ffi:invoke: not supported on this platform", .{});
    return error.Unsupported;
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
    }
}
