//! Emscripten web entry: boots the skript runtime and prints a demo program's
//! result to the JavaScript host through zigzag's wasm terminal platform.
//!
//! The generated Emscripten JS library resolves zigzag's `jsWrite` import to
//! the `Module.skriptWrite` callback supplied by `web/worker.js`. Build with
//! `zig build web` (requires emcc on PATH — the devenv's `emscripten` package
//! provides it).

const std = @import("std");
const skript = @import("skript");
const zz = @import("zigzag");
const zemscripten = @import("zemscripten");
const log = std.log.scoped(.web);

pub const panic = zemscripten.panic;
pub const std_options: std.Options = .{
    .logFn = zemscripten.log,
    .log_level = .warn,
};

/// The runtime backing the pad's skriptPad export, set in main after init.
var g_rt: ?*skript.Runtime = null;
// The output writer and its backing Io are FILE-scope, not main-locals: the
// JS host calls skriptPad after main has returned, and rt.stdout (a pointer
// into the writer) must stay valid across those calls. A main-local writer's
// address dangles once the C stack frame is reused by a later (deep) eval,
// corrupting the buffer and trapping on the next flush.

// SAFETY: main initializes the threaded I/O runtime before any code reads it.
var g_threaded: std.Io.Threaded = undefined;
// SAFETY: main assigns the I/O handle before constructing or exposing the runtime.
var g_io: std.Io = undefined;
// SAFETY: main constructs the file-scope writer before binding it or publishing g_rt.
var g_out: zz.terminal.Terminal.Writer = undefined;

export fn main(argc: c_int, argv: [*][*:0]u8) c_int {
    _ = argc;
    _ = argv;

    g_threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
    g_io = g_threaded.io();
    g_out = .init(g_io, {});
    g_out.bind();
    const io = g_io;
    const out = &g_out;
    const rt = skript.Runtime.initWithConfig(
        std.heap.c_allocator,
        io,
        .{ .max_heap_size = 1 << 26 },
    ) catch |e| {
        const w = out.writer.print("runtime init failed: {s}\n", .{@errorName(e)});
        w catch |we| log.err("write failed: {s}", .{@errorName(we)});
        out.writer.flush() catch |we| log.err("flush failed: {s}", .{@errorName(we)});
        return 1;
    };
    // Stream `(write ...)` / `(display ...)` to the page, mirroring the
    // native hosts (main.zig, repl.zig) that assign rt.stdout themselves.
    rt.stdout = &out.writer;
    g_rt = rt;
    const welcome = out.writer.print("skript pad — type a program, press Run (Ctrl+Enter)\n", .{});
    welcome catch |we| log.err("write failed: {s}", .{@errorName(we)});
    out.writer.flush() catch |we| log.err("flush failed: {s}", .{@errorName(we)});
    return 0;
}

/// source into wasm memory (via the exported malloc) and calls this.
/// Output streams through rt.stdout (zigzag's jsWrite -> Module.skriptWrite ->
/// the pad's output area); returns 0 on success, 1 on error (the message was
/// already streamed).
export fn skriptPad(ptr: [*]const u8, len: usize) c_int {
    const rt = g_rt orelse return 1;
    const src = ptr[0..len];
    const res = rt.evalString(src) catch |e| {
        if (rt.stdout) |w| {
            const we = w.print("error: {s}\n", .{@errorName(e)});
            we catch |wle| log.err("write failed: {s}", .{@errorName(wle)});
            w.flush() catch |fle| log.err("flush failed: {s}", .{@errorName(fle)});
        }
        return 1;
    };
    if (rt.stdout) |w| {
        // Errors-as-values: an uncaught error is a type_error VALUE — stream
        // its name like the old Zig-error path.
        if (res.typ == skript.builtins.type_error) {
            const we = w.print("error: {s}\n", .{@errorName(res.errorCode())});
            we catch |wle| log.err("write failed: {s}", .{@errorName(wle)});
            w.flush() catch |fle| log.err("flush failed: {s}", .{@errorName(fle)});
            return 1;
        }
        const fmt_val: skript.intrinsics.print.FormatValue = .{ .value = res, .runtime = rt, .pretty = true };
        const wr = w.print("{f}\n", .{fmt_val});
        wr catch |wle| log.err("write failed: {s}", .{@errorName(wle)});
        w.flush() catch |fle| log.err("flush failed: {s}", .{@errorName(fle)});
    }
    return 0;
}

comptime {
    // Mark skriptPad no-dead-strip: LLVM's wasm object writer flags the
    // symbol NO_STRIP, and on the emscripten triple that implies EXPORTED
    // (the same path clang's EMSCRIPTEN_KEEPALIVE uses). wasm-ld then keeps
    // the function and exports it; without this, emcc's default export list
    // garbage-collects the unreferenced export and the JS pad can't call it.
    asm (".no_dead_strip skriptPad");
}
