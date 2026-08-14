const std = @import("std");

const skript = @import("../root.zig");
const Value = skript.Value;
const Object = skript.Object;
const Error = skript.Error;
const EvalContext = skript.EvalContext;

const intrin = @import("root.zig");

pub const max_path_bytes = 1024;
pub const max_file_bytes = 1024 * 1024;

fn requireFileIo(ctx: *EvalContext) Error!void {
    try ctx.check();
    if (ctx.mode != .concrete or ctx.execution == .pure_limited or ctx.effects.io != .allow) {
        return error.Denied;
    }
}

fn pathArg(ctx: *EvalContext, value: Value) Error![:0]const u8 {
    try intrin.typeAssert(value, skript.builtins.type_string);
    return ctx.stringBytes(value.obj.toPtr([*:0]const u8), max_path_bytes, .native);
}

fn stringArg(ctx: *EvalContext, value: Value) Error![:0]const u8 {
    try intrin.typeAssert(value, skript.builtins.type_string);
    return ctx.stringBytes(value.obj.toPtr([*:0]const u8), max_file_bytes, .native);
}

fn readExactly(ctx: *EvalContext, file: std.Io.File, bytes: []u8) Error!void {
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(ctx.runtime.io, &buffer);
    reader.interface.readSliceAll(bytes) catch |err| return intrin.mapFileError(err);
    var extra: [1]u8 = undefined;
    const extra_len = reader.interface.readSliceShort(&extra) catch |err| return intrin.mapFileError(err);
    if (extra_len != 0) return error.Unsupported;
}

fn fileSize(ctx: *EvalContext, file: std.Io.File) Error!usize {
    const stat = file.stat(ctx.runtime.io) catch |err| return intrin.mapFileError(err);
    if (stat.kind != .file) return error.Unsupported;
    const size = std.math.cast(usize, stat.size) orelse return error.Unsupported;
    if (size > max_file_bytes) return error.Unsupported;
    return size;
}

/// `(file-read path)` reads cwd-relative text bytes into one Store allocation.
/// Embedded NUL is unsupported. Non-UTF-8 bytes pass through unchanged.
pub fn fileRead(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_string);
    try requireFileIo(ctx);
    const path = try pathArg(ctx, args[0]);

    var file = std.Io.Dir.cwd().openFile(ctx.runtime.io, path, .{ .mode = .read_only }) catch |err| {
        return intrin.mapFileError(err);
    };
    defer file.close(ctx.runtime.io);

    const size = try fileSize(ctx, file);
    try ctx.chargeWork(@intCast(size), 2, .native);
    const contents = try ctx.runtime.store.allocSlice(u8, size + 1);
    errdefer ctx.runtime.store.discardUnpublished(contents.ref) catch unreachable;
    try readExactly(ctx, file, contents.slice[0..size]);
    if (std.mem.indexOfScalar(u8, contents.slice[0..size], 0) != null) return error.Unsupported;
    contents.slice[size] = 0;
    return .string(Object.fromPtr(contents.slice.ptr));
}

/// `(file-read-bytes path)` reads cwd-relative arbitrary bytes into a ByteVector.
pub fn fileReadBytes(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_string);
    try requireFileIo(ctx);
    const path = try pathArg(ctx, args[0]);

    var file = std.Io.Dir.cwd().openFile(ctx.runtime.io, path, .{ .mode = .read_only }) catch |err| {
        return intrin.mapFileError(err);
    };
    defer file.close(ctx.runtime.io);

    const size = try fileSize(ctx, file);
    try ctx.chargeWork(@intCast(size), 1, .native);
    const contents = try ctx.runtime.store.allocSlice(u8, size);
    errdefer ctx.runtime.store.discardUnpublished(contents.ref) catch unreachable;
    try readExactly(ctx, file, contents.slice);
    return intrin.bytes.fromStoreSlice(ctx, contents.slice);
}

fn writeBytes(ctx: *EvalContext, path: []const u8, bytes: []const u8) Error!Value {
    if (bytes.len > max_file_bytes) return error.Unsupported;
    try ctx.chargeWork(@intCast(bytes.len), 1, .native);
    var file = std.Io.Dir.cwd().createFile(ctx.runtime.io, path, .{ .truncate = true }) catch |err| {
        return intrin.mapFileError(err);
    };
    defer file.close(ctx.runtime.io);
    file.writeStreamingAll(ctx.runtime.io, bytes) catch |err| return intrin.mapFileError(err);
    return .true;
}

/// `(file-write path text)` creates or truncates PATH and writes the string bytes.
/// Work and size checks finish before the file is created or truncated.
pub fn fileWrite(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_string);
    try intrin.typeAssert(args[1], skript.builtins.type_string);
    try requireFileIo(ctx);
    const path = try pathArg(ctx, args[0]);
    const contents = try stringArg(ctx, args[1]);
    return writeBytes(ctx, path, contents);
}

/// `(file-write-bytes path bytes)` creates or truncates PATH and writes exact bytes.
/// Work and size checks finish before the file is created or truncated.
pub fn fileWriteBytes(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_string);
    try intrin.typeAssert(args[1], skript.builtins.type_bytevector);
    try requireFileIo(ctx);
    const path = try pathArg(ctx, args[0]);
    const contents = try args[1].byteVectorBytes();
    return writeBytes(ctx, path, contents);
}

/// `(file-exists? path)` returns whether a filesystem entry exists at PATH.
pub fn fileExists(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_string);
    try requireFileIo(ctx);
    const path = try pathArg(ctx, args[0]);
    try ctx.chargeWork(1, 1, .native);
    _ = std.Io.Dir.cwd().statFile(ctx.runtime.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .false,
        else => return intrin.mapFileError(err),
    };
    return .true;
}

fn valueString(rt: *skript.Runtime, bytes: []const u8) Error!Value {
    const allocation = try rt.store.allocSlice(u8, bytes.len + 1);
    @memcpy(allocation.slice[0..bytes.len], bytes);
    allocation.slice[bytes.len] = 0;
    return .string(Object.fromPtr(allocation.slice.ptr));
}

fn evalFormat(
    comptime format: []const u8,
    rt: *skript.Runtime,
    args: anytype,
) !Value {
    const source = try std.fmt.allocPrint(std.testing.allocator, format, args);
    defer std.testing.allocator.free(source);
    return rt.evalString(source);
}

fn stringBytes(value: Value) []const u8 {
    return std.mem.span(value.obj.toPtr([*:0]const u8));
}

const LimitedContext = struct {
    ledger: EvalContext.Budget,
    lease: EvalContext.Budget.Lease,
    account: EvalContext.Budget.AccountAllocator,
    output: [8]u8,
    writer: std.Io.Writer,
    ctx: EvalContext,

    fn init(
        self: *LimitedContext,
        rt: *skript.Runtime,
        limits: EvalContext.Budget.Limits,
        options: EvalContext.LimitedOptions,
    ) !void {
        self.ledger = EvalContext.Budget.init(rt.io, 1, limits);
        self.lease = try EvalContext.Budget.Lease.root(&self.ledger, limits.work);
        self.account = EvalContext.Budget.AccountAllocator.init(std.testing.allocator, &self.lease, .native);
        self.writer = .fixed(&self.output);
        self.ctx = try EvalContext.limited(rt, rt.intrinsics.registryVersion(), &self.account, .{
            .writer = &self.writer,
            .bounded_memory = true,
        }, options);
    }
};

test "whole-file text and binary operations round-trip bytes and clean up files" {
    const rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const text_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/text.txt", .{tmp.sub_path});
    defer std.testing.allocator.free(text_path);
    const binary_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/binary.dat", .{tmp.sub_path});
    defer std.testing.allocator.free(binary_path);
    const raw_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/raw.dat", .{tmp.sub_path});
    const nonutf8_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/nonutf8.dat",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(nonutf8_path);
    defer std.testing.allocator.free(raw_path);
    const missing_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/missing", .{tmp.sub_path});
    defer std.testing.allocator.free(missing_path);

    try std.testing.expectEqual(Value.true, try evalFormat("(file-write \"{s}\" \"hello\")", rt, .{text_path}));
    const text = try evalFormat("(file-read \"{s}\")", rt, .{text_path});
    try std.testing.expectEqualStrings("hello", stringBytes(text));
    try std.testing.expectEqual(Value.true, try evalFormat("(file-exists? \"{s}\")", rt, .{text_path}));
    try std.testing.expectEqual(Value.false, try evalFormat("(file-exists? \"{s}\")", rt, .{missing_path}));
    try std.testing.expectError(error.Unbound, evalFormat("(file-read \"{s}\")", rt, .{missing_path}));

    try std.testing.expectEqual(Value.true, try evalFormat(
        "(file-write-bytes \"{s}\" (ByteVector (u8 0) (u8 65) (u8 128) (u8 255)))",
        rt,
        .{binary_path},
    ));
    const binary = try evalFormat("(file-read-bytes \"{s}\")", rt, .{binary_path});
    try std.testing.expectEqualSlices(u8, &.{ 0, 65, 128, 255 }, try binary.byteVectorBytes());

    var raw = try tmp.dir.createFile(rt.io, "raw.dat", .{});
    defer raw.close(rt.io);
    try raw.writeStreamingAll(rt.io, &.{ 'a', 0xff, 0, 0x80 });
    var nonutf8 = try tmp.dir.createFile(rt.io, "nonutf8.dat", .{});
    defer nonutf8.close(rt.io);
    const nonutf8_source = [_]u8{ 'a', 0xff, 0x80 };
    try nonutf8.writeStreamingAll(rt.io, &nonutf8_source);
    const nonutf8_text = try evalFormat("(file-read \"{s}\")", rt, .{nonutf8_path});
    try std.testing.expectEqualSlices(u8, &nonutf8_source, stringBytes(nonutf8_text));
    const raw_path_value = try valueString(rt, raw_path);
    const live_before = rt.store.stats().live_objects;
    try std.testing.expectError(error.Unsupported, fileRead(
        rt.context(),
        .nil,
        .nil,
        &.{raw_path_value},
    ));
    try std.testing.expectEqual(live_before, rt.store.stats().live_objects);
    try std.testing.expectError(error.Unsupported, evalFormat("(file-read \"{s}\")", rt, .{raw_path}));
    const raw_binary = try evalFormat("(file-read-bytes \"{s}\")", rt, .{raw_path});
    try std.testing.expectEqualSlices(u8, &.{ 'a', 0xff, 0, 0x80 }, try raw_binary.byteVectorBytes());

    try std.testing.expectError(
        error.ArityMismatch,
        evalFormat("(file-write \"{s}\" \"a\" \"b\")", rt, .{text_path}),
    );
    try std.testing.expectError(error.TypeMismatch, rt.evalString("(file-read 42)"));
}

test "file policy and exhausted work do not create or truncate files" {
    const rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/guarded.txt", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    const path_value = try valueString(rt, path);
    const new_value = try valueString(rt, "replacement");
    try std.testing.expectEqual(
        Value.true,
        try evalFormat("(file-write \"{s}\" \"original\")", rt, .{path}),
    );
    var long_path_bytes: [max_path_bytes + 1]u8 = undefined;
    @memset(&long_path_bytes, 'x');
    const long_path = try valueString(rt, &long_path_bytes);
    const long_path_ctx = rt.context();
    try std.testing.expectError(error.Unsupported, fileExists(long_path_ctx, .nil, .nil, &.{long_path}));

    var output_bytes: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_bytes);
    var denied = EvalContext.trusted(rt.static, rt, rt.intrinsics.registryVersion(), .{ .writer = &writer });
    denied.effects.io = .deny;
    try std.testing.expectError(error.Denied, fileWrite(&denied, .nil, .nil, &.{ path_value, new_value }));
    denied.effects.io = .allow;
    denied.mode = .dry;
    try std.testing.expectError(error.Denied, fileWrite(&denied, .nil, .nil, &.{ path_value, new_value }));
    const denied_unchanged = try evalFormat("(file-read \"{s}\")", rt, .{path});
    try std.testing.expectEqualStrings("original", stringBytes(denied_unchanged));

    var limited: LimitedContext = undefined;
    try limited.init(rt, .{ .work = @intCast(path.len + 1) }, .{
        .effects = .{ .io = .allow },
    });
    try std.testing.expectError(error.Exhausted, fileWrite(&limited.ctx, .nil, .nil, &.{ path_value, new_value }));
    const unchanged = try evalFormat("(file-read \"{s}\")", rt, .{path});
    try std.testing.expectEqualStrings("original", stringBytes(unchanged));
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
    }
}
