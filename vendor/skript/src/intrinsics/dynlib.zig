const std = @import("std");
const builtin = @import("builtin");
const win = std.os.windows;
const log = std.log.scoped(.dynlib);

const skript = @import("../root.zig");
const Error = skript.Error;
const Value = skript.Value;
const EvalContext = skript.EvalContext;
const Runtime = skript.Runtime;

extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const u16) callconv(.winapi) ?win.HMODULE;
extern "kernel32" fn FreeLibrary(hLibModule: win.HMODULE) callconv(.winapi) win.BOOL;
extern "kernel32" fn GetProcAddress(hModule: win.HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?win.FARPROC;
extern "kernel32" fn GetLastError() callconv(.winapi) win.DWORD;
const dynamic_name_capacity: usize = 4096;

const dynamic_library_magic: u64 = 0x534b_5249_5054_444c;
const function_symbol_magic: u64 = 0x534b_5249_5054_4453;
const LibraryState = struct {
    magic: u64,
    store_tag: u16,
    open: bool,
    next_library: ?*anyopaque = null,
    symbols_head: ?*anyopaque = null,
    mutex: std.Io.Mutex = .init,
    io: std.Io,
};
pub const FunctionSymbol = struct {
    magic: u64,
    library: *anyopaque,
    pointer: *anyopaque,
    next: ?*anyopaque = null,
};
const NativeLibraryHandle = if (builtin.os.tag == .windows)
    win.HMODULE
else if (builtin.link_mode == .static)
    @FieldType(std.DynLib, "inner")
else
    std.DynLib;
const DynamicLibrary = struct {
    state: LibraryState,
    handle: NativeLibraryHandle,
};

fn traceLibrary(data: *const anyopaque, extent: usize, visitor: *skript.Store.MarkVisitor) anyerror!void {
    if (extent != 1) return error.UntracedAllocation;
    const library: *const DynamicLibrary = @ptrCast(@alignCast(data));
    if (library.state.next_library) |next| try visitor.visitAddress(@intFromPtr(next));
    if (library.state.symbols_head) |symbol| try visitor.visitAddress(@intFromPtr(symbol));
}

fn traceSymbol(data: *const anyopaque, extent: usize, visitor: *skript.Store.MarkVisitor) anyerror!void {
    if (extent != 1) return error.UntracedAllocation;
    const symbol: *const FunctionSymbol = @ptrCast(@alignCast(data));
    try visitor.visitAddress(@intFromPtr(symbol.library));
    if (symbol.next) |next| try visitor.visitAddress(@intFromPtr(next));
}

fn hasStoreRef(obj: skript.Object) bool {
    if (obj == .null) return false;
    const ref = obj.toRef();
    return !ref.isNull() and ref.tag != 0 and ref.address() != 0;
}

fn libraryHandle(rt: *Runtime, value: Value) Error!*DynamicLibrary {
    if (!value.isOpaque() or !hasStoreRef(value.obj)) return error.TypeMismatch;
    const ref = value.obj.toRef();
    rt.dynlib_list_mutex.lockUncancelable(rt.io);
    defer rt.dynlib_list_mutex.unlock(rt.io);

    var library = rt.dynlib_head;
    while (library) |raw| {
        const handle: *DynamicLibrary = @ptrCast(@alignCast(raw));
        if (@intFromPtr(handle) == ref.address() and handle.state.store_tag == ref.tag)
            return handle;
        library = handle.state.next_library;
    }
    return error.TypeMismatch;
}
fn symbolLibrary(symbol: *FunctionSymbol) *DynamicLibrary {
    return @ptrCast(@alignCast(symbol.library));
}

pub fn functionSymbol(rt: *Runtime, obj: skript.Object) ?*FunctionSymbol {
    if (!hasStoreRef(obj)) return null;
    const address = obj.toRef().address();

    rt.dynlib_list_mutex.lockUncancelable(rt.io);
    defer rt.dynlib_list_mutex.unlock(rt.io);
    var library = rt.dynlib_head;
    while (library) |raw| {
        const handle: *DynamicLibrary = @ptrCast(@alignCast(raw));
        const next = handle.state.next_library;
        handle.state.mutex.lockUncancelable(handle.state.io);
        defer handle.state.mutex.unlock(handle.state.io);

        var symbol = handle.state.symbols_head;
        while (symbol) |entry| {
            const token: *FunctionSymbol = @ptrCast(@alignCast(entry));
            if (@intFromPtr(token) == address) {
                if (token.magic == function_symbol_magic and
                    @intFromPtr(token.library) == @intFromPtr(handle))
                    return token;
                return null;
            }
            symbol = token.next;
        }
        library = next;
    }
    return null;
}

pub fn validateFunctionSymbol(symbol: *FunctionSymbol) Error!*const fn () callconv(.c) void {
    const handle = symbolLibrary(symbol);
    handle.state.mutex.lockUncancelable(handle.state.io);
    defer handle.state.mutex.unlock(handle.state.io);
    if (symbol.magic != function_symbol_magic or
        @intFromPtr(symbol.library) != @intFromPtr(handle) or
        handle.state.magic != dynamic_library_magic or
        !handle.state.open)
        return error.Unsupported;
    return @ptrCast(@alignCast(symbol.pointer));
}

/// Keeps the library open until the caller releases the returned function pointer.
pub fn acquireFunction(symbol: *FunctionSymbol) Error!*const fn () callconv(.c) void {
    const handle = symbolLibrary(symbol);
    handle.state.mutex.lockUncancelable(handle.state.io);
    if (symbol.magic != function_symbol_magic or
        @intFromPtr(symbol.library) != @intFromPtr(handle) or
        handle.state.magic != dynamic_library_magic or
        !handle.state.open)
    {
        handle.state.mutex.unlock(handle.state.io);
        return error.Unsupported;
    }
    return @ptrCast(@alignCast(symbol.pointer));
}

pub fn releaseFunction(symbol: *FunctionSymbol) void {
    const handle = symbolLibrary(symbol);
    handle.state.mutex.unlock(handle.state.io);
}

fn publishLibrary(rt: *Runtime, native_handle: NativeLibraryHandle) Error!Value {
    return publishLibraryWithFailureCloser(rt, native_handle, &closeUnpublished);
}

fn publishLibraryWithFailureCloser(
    rt: *Runtime,
    native_handle: NativeLibraryHandle,
    release_on_failure: *const fn (NativeLibraryHandle) void,
) Error!Value {
    const ref = rt.store.createTraced(DynamicLibrary, traceLibrary) catch |err| {
        release_on_failure(native_handle);
        return err;
    };
    const handle = ref.deref(DynamicLibrary);
    handle.* = .{
        .state = .{
            .magic = dynamic_library_magic,
            .store_tag = ref.tag,
            .open = true,
            .io = rt.io,
        },
        .handle = native_handle,
    };

    rt.dynlib_list_mutex.lockUncancelable(rt.io);
    handle.state.next_library = rt.dynlib_head;
    rt.dynlib_head = @ptrCast(handle);
    rt.dynlib_list_mutex.unlock(rt.io);
    return .opaq(ref.toObject());
}

fn closeUnpublished(native_handle: NativeLibraryHandle) void {
    if (builtin.os.tag == .windows) {
        _ = FreeLibrary(native_handle);
    } else {
        var handle = native_handle;
        handle.close();
    }
}

fn closeLibrary(handle: *DynamicLibrary) void {
    handle.state.mutex.lockUncancelable(handle.state.io);
    defer handle.state.mutex.unlock(handle.state.io);
    if (handle.state.magic != dynamic_library_magic or !handle.state.open) return;
    handle.state.open = false;
    if (builtin.os.tag == .windows) {
        _ = FreeLibrary(handle.handle);
    } else {
        handle.handle.close();
    }
}

pub fn deinitRuntimeLibraries(rt: *Runtime) void {
    rt.dynlib_list_mutex.lockUncancelable(rt.io);
    var library = rt.dynlib_head;
    rt.dynlib_head = null;
    rt.dynlib_list_mutex.unlock(rt.io);

    while (library) |raw| {
        const handle: *DynamicLibrary = @ptrCast(@alignCast(raw));
        library = handle.state.next_library;
        handle.state.next_library = null;
        closeLibrary(handle);
    }
}

/// The Runtime owns these linked Store allocations until library teardown.
/// Symbol links are raw pointers; each token must stay live even when its
/// returned Value is no longer reachable from Skript code.
pub fn traceRuntimeRoots(rt: *Runtime, visitor: *skript.Store.MarkVisitor) anyerror!void {
    var library = rt.dynlib_head;
    while (library) |raw| {
        const handle: *DynamicLibrary = @ptrCast(@alignCast(raw));
        try visitor.visitAddress(@intFromPtr(handle));
        var symbol = handle.state.symbols_head;
        while (symbol) |entry| {
            const token: *FunctionSymbol = @ptrCast(@alignCast(entry));
            try visitor.visitAddress(@intFromPtr(token));
            symbol = token.next;
        }
        library = handle.state.next_library;
    }
}

fn stringArgument(value: Value) ?[]const u8 {
    if (!value.isString() or value.obj == .null or hasStoreRef(value.obj)) return null;
    const start = value.obj.toPtr([*:0]const u8);
    var length: usize = 0;
    while (length < dynamic_name_capacity) : (length += 1) {
        if (start[length] == 0) return start[0..length];
    }
    return null;
}

pub fn open(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try requireTrustedConcrete(ctx);
    const rt = ctx.runtime;
    if (args.len != 1) {
        log.err("dynamic-library:open: expected a string argument", .{});
        return .nil;
    }
    const path_u8 = stringArgument(args[0]) orelse {
        log.err("dynamic-library:open: expected a non-null string argument", .{});
        return .nil;
    };

    if (builtin.os.tag == .windows) return openWindows(rt, path_u8);
    if (builtin.link_mode == .static) {
        const elf_dyn_lib = @FieldType(std.DynLib, "inner");
        const ld_library_path = std.c.getenv("LD_LIBRARY_PATH") orelse null;
        const dyn_lib = elf_dyn_lib.open(path_u8, std.mem.span(ld_library_path)) catch |err| {
            log.err("dynamic-library:open `{s}` failed: {any}", .{ path_u8, err });
            return .nil;
        };
        return publishLibrary(rt, dyn_lib);
    }
    const dyn_lib = std.DynLib.open(path_u8) catch |err| {
        log.err("dynamic-library:open `{s}` failed: {any}", .{ path_u8, err });
        return .nil;
    };
    return publishLibrary(rt, dyn_lib);
}

fn requireTrustedConcrete(ctx: *EvalContext) Error!void {
    if (!ctx.isUnrestricted()) return error.Denied;
    try ctx.check();
}

fn openWindows(rt: *Runtime, path_u8: []const u8) Error!Value {
    // SAFETY: filled by utf8ToUtf16Le before read.
    var buf: [260]u16 = undefined;
    if (path_u8.len >= buf.len) {
        log.err("dynamic-library:open: path exceeds MAX_PATH ({d} bytes)", .{path_u8.len});
        return .nil;
    }
    const len16 = std.unicode.utf8ToUtf16Le(buf[0..], path_u8) catch |err| {
        log.err("dynamic-library:open: invalid UTF-8 in path: {any}", .{err});
        return .nil;
    };
    buf[len16] = 0;
    const path_w: [*:0]const u16 = buf[0..len16 :0].ptr;
    const handle = LoadLibraryW(path_w) orelse {
        log.err("dynamic-library:open: LoadLibraryW failed: {x}", .{GetLastError()});
        return .nil;
    };
    return publishLibrary(rt, handle);
}

pub fn close(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try requireTrustedConcrete(ctx);
    if (args.len != 1) {
        log.err("dynamic-library:close: expected 1 argument", .{});
        return .nil;
    }
    const handle = libraryHandle(ctx.runtime, args[0]) catch {
        return .nil;
    };
    closeLibrary(handle);
    return .nil;
}

pub fn lookup(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try requireTrustedConcrete(ctx);
    if (args.len != 2) {
        log.err("dynamic-library:lookup: expected (opaque, string) arguments", .{});
        return .nil;
    }
    const handle = libraryHandle(ctx.runtime, args[0]) catch {
        return .nil;
    };
    const sym = stringArgument(args[1]) orelse {
        log.err("dynamic-library:lookup: expected a non-null symbol string", .{});
        return .nil;
    };

    handle.state.mutex.lockUncancelable(handle.state.io);
    defer handle.state.mutex.unlock(handle.state.io);
    if (!handle.state.open) {
        log.err("dynamic-library:lookup: library is closed", .{});
        return .nil;
    }
    const ptr = lookupNative(handle, sym) orelse {
        log.err("dynamic-library:lookup failed: {s}", .{sym});
        return .nil;
    };
    const ref = try ctx.runtime.store.createTraced(FunctionSymbol, traceSymbol);
    const symbol = ref.deref(FunctionSymbol);
    symbol.* = .{
        .magic = function_symbol_magic,
        .library = @ptrCast(handle),
        .pointer = ptr,
        .next = handle.state.symbols_head,
    };
    handle.state.symbols_head = @ptrCast(symbol);
    return .opaq(ref.toObject());
}

fn lookupNative(handle: *DynamicLibrary, sym: []const u8) ?*anyopaque {
    var buf: [1024]u8 = undefined;
    var bufalloc = std.heap.FixedBufferAllocator.init(&buf);
    const name = bufalloc.allocator().dupeSentinel(u8, sym, 0) catch |err| {
        log.err("dynamic-library:lookup oom: {any}", .{err});
        return null;
    };
    if (builtin.os.tag == .windows) {
        const ptr = GetProcAddress(handle.handle, name) orelse {
            log.err("dynamic-library:lookup: GetProcAddress failed: {x}", .{GetLastError()});
            return null;
        };
        return @ptrCast(ptr);
    }
    if (builtin.link_mode == .static) {
        const address = handle.handle.lookupAddress("", name) orelse return null;
        return @ptrFromInt(address);
    }
    return handle.handle.lookup(*anyopaque, name);
}

test "dynlib close and runtime cleanup are idempotent" {
    if (builtin.os.tag != .linux or builtin.link_mode == .static) return error.SkipZigTest;

    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const ctx = rt.context();
    const library = try open(ctx, .nil, .nil, &.{
        Value.string(skript.Object.fromPtr("libc.so.6".ptr)),
    });

    _ = try close(ctx, .nil, .nil, &.{library});
    _ = try close(ctx, .nil, .nil, &.{library});
    deinitRuntimeLibraries(rt);
    deinitRuntimeLibraries(rt);
    try std.testing.expectEqual(
        skript.builtins.type_nil,
        (try lookup(ctx, .nil, .nil, &.{ library, Value.string(skript.Object.fromPtr("abs".ptr)) })).typ,
    );
}
test "collection retains linked dynamic libraries and function symbols" {
    if (builtin.os.tag != .linux or builtin.link_mode == .static) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const ctx = rt.context();
    const library = try open(ctx, .nil, .nil, &.{
        Value.string(skript.Object.fromPtr("libc.so.6".ptr)),
    });
    const symbol = try lookup(ctx, .nil, .nil, &.{
        library,
        Value.string(skript.Object.fromPtr("abs".ptr)),
    });

    try rt.collect();
    _ = try rt.store.derefChecked(DynamicLibrary, library.obj.toRef());
    _ = try rt.store.derefChecked(FunctionSymbol, symbol.obj.toRef());
    const resolved = functionSymbol(rt, symbol.obj) orelse return error.InvalidRef;
    _ = try validateFunctionSymbol(resolved);
}

test "dynlib rejects unrelated Store objects as library handles" {
    if (builtin.os.tag != .linux or builtin.link_mode == .static) return error.SkipZigTest;

    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const ctx = rt.context();
    const library = try open(ctx, .nil, .nil, &.{
        Value.string(skript.Object.fromPtr("libc.so.6".ptr)),
    });
    const unrelated = try rt.store.create([2]u64);

    _ = try close(ctx, .nil, .nil, &.{Value.opaq(unrelated.toObject())});
    const symbol = try lookup(ctx, .nil, .nil, &.{
        library,
        Value.string(skript.Object.fromPtr("abs".ptr)),
    });
    try std.testing.expect(symbol.isOpaque());
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
    }
}
fn exhaustStoreFor(comptime T: type, rt: *Runtime) void {
    while (rt.store.create([65536]u8)) |_| {} else |err| {
        std.debug.assert(err == error.OutOfMemory);
    }
    while (rt.store.create(T)) |_| {} else |err| {
        std.debug.assert(err == error.OutOfMemory);
    }
}

var dynlib_test_unpublished_closes: usize = 0;

fn dynlibTestReleaseUnpublished(handle: NativeLibraryHandle) void {
    dynlib_test_unpublished_closes += 1;
    closeUnpublished(handle);
}

test "dynlib releases an acquired native handle once when Store publication exhausts" {
    if (builtin.os.tag != .linux or builtin.link_mode == .static) return error.SkipZigTest;

    var rt = try Runtime.initWithConfig(std.testing.allocator, std.testing.io, .{
        .heap_size = 8 * 1024 * 1024,
        .max_heap_size = 8 * 1024 * 1024,
    });
    defer rt.deinit();
    exhaustStoreFor(DynamicLibrary, rt);
    const live_objects = rt.store.stats().live_objects;
    const native_handle = try std.DynLib.open("libc.so.6");
    dynlib_test_unpublished_closes = 0;

    try std.testing.expectError(
        error.OutOfMemory,
        publishLibraryWithFailureCloser(rt, native_handle, &dynlibTestReleaseUnpublished),
    );
    try std.testing.expectEqual(@as(usize, 1), dynlib_test_unpublished_closes);
    try std.testing.expectEqual(live_objects, rt.store.stats().live_objects);
    try std.testing.expectEqual(@as(?*anyopaque, null), rt.dynlib_head);
}
test "dynlib releases a native handle when Store publication is exhausted" {
    if (builtin.os.tag != .linux or builtin.link_mode == .static) return error.SkipZigTest;

    var rt = try Runtime.initWithConfig(std.testing.allocator, std.testing.io, .{
        .heap_size = 8 * 1024 * 1024,
        .max_heap_size = 8 * 1024 * 1024,
    });
    defer rt.deinit();
    exhaustStoreFor(DynamicLibrary, rt);
    const live_objects = rt.store.stats().live_objects;

    try std.testing.expectError(
        error.OutOfMemory,
        open(rt.context(), .nil, .nil, &.{
            Value.string(skript.Object.fromPtr("libc.so.6".ptr)),
        }),
    );
    try std.testing.expectEqual(live_objects, rt.store.stats().live_objects);
}
test "dynlib lookup releases its library lock when Store publication exhausts" {
    if (builtin.os.tag != .linux or builtin.link_mode == .static) return error.SkipZigTest;

    var rt = try Runtime.initWithConfig(std.testing.allocator, std.testing.io, .{
        .heap_size = 8 * 1024 * 1024,
        .max_heap_size = 8 * 1024 * 1024,
    });
    defer rt.deinit();
    const ctx = rt.context();
    const library = try open(ctx, .nil, .nil, &.{
        Value.string(skript.Object.fromPtr("libc.so.6".ptr)),
    });
    exhaustStoreFor(FunctionSymbol, rt);
    const live_objects = rt.store.stats().live_objects;

    try std.testing.expectError(
        error.OutOfMemory,
        lookup(ctx, .nil, .nil, &.{
            library,
            Value.string(skript.Object.fromPtr("abs".ptr)),
        }),
    );
    try std.testing.expectEqual(live_objects, rt.store.stats().live_objects);
    _ = try close(ctx, .nil, .nil, &.{library});
    deinitRuntimeLibraries(rt);
}
