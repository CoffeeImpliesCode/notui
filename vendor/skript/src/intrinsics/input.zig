const std = @import("std");

const skript = @import("../root.zig");
const Value = skript.Value;
const Error = skript.Error;
const EvalContext = skript.EvalContext;

const intrin = @import("root.zig");

const max_input_bytes = 1024 * 1024;

/// Reads block on the runner thread. A blocked call pauses every scheduled process.
fn inputReader(ctx: *EvalContext) Error!*std.Io.Reader {
    try ctx.check();
    if (ctx.mode != .concrete or ctx.execution == .pure_limited or ctx.effects.io != .allow) {
        return error.Denied;
    }
    if (skript.scheduler.current_process == null) return error.Unimplemented;
    return ctx.runtime.stdin_reader orelse error.Unimplemented;
}

fn takeByte(ctx: *EvalContext, reader: *std.Io.Reader) Error!?u8 {
    try ctx.chargeWork(1, 1, .native);
    var one: [1]u8 = undefined;
    const count = reader.readSliceShort(&one) catch return error.Unsupported;
    if (count == 0) return null;
    return one[0];
}

fn appendByte(ctx: *EvalContext, bytes: *std.ArrayList(u8), byte: u8) Error!void {
    if (bytes.items.len == max_input_bytes) return error.Unsupported;
    try bytes.append(ctx.scratch, byte);
}

fn byteSlice(ctx: *EvalContext, bytes: []const u8) Error!Value {
    return intrin.bytes.fromBytes(ctx, bytes);
}

/// `(read-line)` returns a line without LF. It keeps CR in CRLF input.
/// This operation is synchronous and blocks the runner until input or EOF.
pub fn readLine(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 0);
    const reader = try inputReader(ctx);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(ctx.scratch);
    var saw_newline = false;
    while (true) {
        const byte = (try takeByte(ctx, reader)) orelse break;
        if (byte == 0) return error.Unsupported;
        if (byte == '\n') {
            saw_newline = true;
            break;
        }
        try appendByte(ctx, &line, byte);
    }
    if (line.items.len == 0 and !saw_newline) return .nil;
    return intrin.string.storeString(ctx, line.items);
}

/// `(read-char)` returns one input byte as a string, or nil at EOF.
/// This operation is synchronous and blocks the runner until input or EOF.
pub fn readChar(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 0);
    const reader = try inputReader(ctx);
    const byte = (try takeByte(ctx, reader)) orelse return .nil;
    if (byte == 0) return error.Unsupported;
    return intrin.string.storeString(ctx, &.{byte});
}

/// `(read-byte)` returns one input byte as u8, or nil at EOF.
/// This operation is synchronous and blocks the runner until input or EOF.
pub fn readByte(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 0);
    const reader = try inputReader(ctx);
    return .u8((try takeByte(ctx, reader)) orelse return .nil);
}

fn collectRemaining(ctx: *EvalContext, reader: *std.Io.Reader, reject_nul: bool) Error!std.ArrayList(u8) {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(ctx.scratch);
    while (true) {
        const byte = (try takeByte(ctx, reader)) orelse return bytes;
        if (reject_nul and byte == 0) return error.Unsupported;
        try appendByte(ctx, &bytes, byte);
    }
}

/// `(read-all)` returns all remaining input bytes as a string.
/// It returns an empty string at immediate EOF and rejects NUL bytes.
/// This operation is synchronous and blocks the runner until EOF.
pub fn readAll(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 0);
    const reader = try inputReader(ctx);
    var bytes = try collectRemaining(ctx, reader, true);
    defer bytes.deinit(ctx.scratch);
    return intrin.string.storeString(ctx, bytes.items);
}

/// `(read-all-bytes)` returns every remaining input byte in a ByteVector.
/// This operation is synchronous and blocks the runner until EOF.
pub fn readAllBytes(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 0);
    const reader = try inputReader(ctx);
    var bytes = try collectRemaining(ctx, reader, false);
    defer bytes.deinit(ctx.scratch);
    return byteSlice(ctx, bytes.items);
}

fn expectString(value: Value, expected: []const u8) !void {
    try std.testing.expectEqual(skript.builtins.type_string, value.typ);
    try std.testing.expectEqualStrings(expected, std.mem.span(value.obj.toPtr([*:0]const u8)));
}

fn evalInput(rt: *skript.Runtime, source: []const u8) Error!Value {
    const process = try rt.spawnEval(source);
    return rt.awaitProcess(process);
}

test "stdin reads distinguish EOF, empty lines, CRLF, and final lines" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var reader = std.Io.Reader.fixed("first\r\n\nlast");
    rt.stdin_reader = &reader;

    try expectString(try evalInput(rt, "(read-line)"), "first\r");
    try expectString(try evalInput(rt, "(read-line)"), "");
    try expectString(try evalInput(rt, "(read-line)"), "last");
    try std.testing.expectEqual(Value.nil, try evalInput(rt, "(read-line)"));
}

test "stdin text and binary reads preserve arbitrary non-NUL bytes" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const source = [_]u8{ 'a', 0xff, 0x80 };
    var reader = std.Io.Reader.fixed(&source);
    rt.stdin_reader = &reader;

    const text = try evalInput(rt, "(read-all)");
    try std.testing.expectEqualSlices(u8, &source, std.mem.span(text.obj.toPtr([*:0]const u8)));

    const binary_source = [_]u8{ 0, 0xff, 0x80 };
    var binary_reader = std.Io.Reader.fixed(&binary_source);
    rt.stdin_reader = &binary_reader;
    const binary = try evalInput(rt, "(read-all-bytes)");
    try std.testing.expectEqualSlices(u8, &binary_source, try binary.byteVectorBytes());
}

test "stdin EOF and text NUL contracts hold for each reader" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var empty_reader = std.Io.Reader.fixed(&.{});
    rt.stdin_reader = &empty_reader;
    try std.testing.expectEqual(Value.nil, try evalInput(rt, "(read-line)"));
    try std.testing.expectEqual(Value.nil, try evalInput(rt, "(read-char)"));
    try std.testing.expectEqual(Value.nil, try evalInput(rt, "(read-byte)"));
    try expectString(try evalInput(rt, "(read-all)"), "");
    const empty_bytes = try evalInput(rt, "(read-all-bytes)");
    try std.testing.expectEqualSlices(u8, &.{}, try empty_bytes.byteVectorBytes());

    var byte_reader = std.Io.Reader.fixed(&.{0xff});
    rt.stdin_reader = &byte_reader;
    try std.testing.expectEqual(Value.u8(255), try evalInput(rt, "(read-byte)"));
    try std.testing.expectEqual(Value.nil, try evalInput(rt, "(read-byte)"));

    var nul_line_reader = std.Io.Reader.fixed(&.{ 'a', 0, '\n' });
    rt.stdin_reader = &nul_line_reader;
    try std.testing.expectError(error.Unsupported, evalInput(rt, "(read-line)"));

    var nul_char_reader = std.Io.Reader.fixed(&.{0});
    rt.stdin_reader = &nul_char_reader;
    try std.testing.expectError(error.Unsupported, evalInput(rt, "(read-char)"));

    var all_nul_reader = std.Io.Reader.fixed(&.{ 'a', 0, 'b' });
    rt.stdin_reader = &all_nul_reader;
    try std.testing.expectError(error.Unsupported, evalInput(rt, "(read-all)"));
}

test "stdin reads reject denied policy and missing reader" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var input = std.Io.Reader.fixed("x");
    rt.stdin_reader = &input;

    var output_buffer: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    var denied = EvalContext.trusted(rt.static, rt, rt.intrinsics.registryVersion(), .{ .writer = &writer });
    denied.effects.io = .deny;
    try std.testing.expectError(error.Denied, readByte(&denied, .nil, .nil, &.{}));
    try std.testing.expectEqual(@as(usize, 0), input.seek);
    const outside_process = rt.context();
    try std.testing.expectError(error.Unimplemented, readByte(outside_process, .nil, .nil, &.{}));

    rt.stdin_reader = null;
    try std.testing.expectError(error.Unimplemented, evalInput(rt, "(read-byte)"));
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
    }
}
