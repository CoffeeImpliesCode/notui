const std = @import("std");
const repl = @import("repl.zig");
const skript = @import("skript");

pub const tracy_impl = @import("tracy_impl");
pub const tracy_options: tracy.Options = .{
    .on_demand = false,
    .no_broadcast = false,
    .only_localhost = false,
    .only_ipv4 = false,
    .delayed_init = false,
    .manual_lifetime = false,
    .verbose = false,
    .data_port = null,
    .broadcast_port = null,
    .default_callstack_depth = 0,
};

/// Suppress debug/info log output to avoid TUI flickering.
pub const std_options: std.Options = .{
    .log_level = .warn,
};

const tracy = @import("tracy");

fn printUsage(io: std.Io) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout_writer.interface.print(
        \\Skript Interpreter (© 2026 CoffeeImpliesCode)
        \\Usage: skript [options] [file|-|repl]
        \\Options include --regvm, --no-bytecode-opts, and
        \\--repl-no-highlight. -h and --help print this usage and exit 0.
        \\Use -- before a dash-prefixed filename.
        \\--no-bytecode-opts disables every register-VM compiler optimization (debugging/
        \\benchmarking against the default). --repl-no-highlight turns
        \\off REPL query highlighting (plain history text, no
        \\tree-sitter engine) for pipelines and dumb terminals.
        \\EXAMPLES:
        \\    skript test.pt
        \\    skript --no-bytecode-opts test.pt
        \\    skript -
        \\    skript repl
    ++ "\n", .{});
    try stdout_writer.interface.flush();
}

fn exitWithCliError(comptime format: []const u8, io: std.Io, args: anytype) noreturn {
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    stderr_writer.interface.print(format, args) catch {
        std.process.exit(2);
    };
    stderr_writer.interface.flush() catch {
        std.process.exit(2);
    };
    std.process.exit(2);
}

/// CLI failures are Skript errors, not Zig host stack traces. Retained
/// source trees and captured VM frames remain valid until process exit.
fn exitWithRuntimeError(
    rt: *skript.Runtime,
    problem: skript.Value,
    raised: skript.Value,
    input_path: ?[]const u8,
) noreturn {
    var stderr_buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stderr().writer(rt.io, &stderr_buf);
    const writer = &file_writer.interface;
    const error_code = problem.errorCode();
    if (error_code == error.Raised) {
        writer.print("skript: uncaught raise: {f}\n", .{
            skript.intrinsics.print.FormatValue{ .runtime = rt, .value = raised },
        }) catch std.process.exit(1);
    } else {
        writer.print("skript: {s}\n", .{@errorName(error_code)}) catch std.process.exit(1);
    }
    const site = problem.errorSite();
    if (site.line != 0) {
        const path: []const u8 = if (!site.file.isNil())
            std.mem.span(site.file.obj.toPtr([*:0]const u8))
        else
            input_path orelse "<input>";
        writer.print("{s}:{d}:{d}\n", .{ path, site.line, site.col }) catch std.process.exit(1);
    } else if (!site.source.isNil()) {
        if (rt.dfsNodeLocation(site.source, site.idx)) |loc| {
            const path: []const u8 = if (loc.file) |file| std.mem.span(file) else input_path orelse "<input>";
            writer.print("{s}:{d}:{d}\n", .{ path, loc.line, loc.col }) catch std.process.exit(1);
        }
    }
    for (problem.errorFrames()) |frame| {
        const name: []const u8 = if (frame.name) |sym| sym.* else "<anonymous>";
        if (frame.site.line != 0) {
            const path: []const u8 = if (!frame.site.file.isNil())
                std.mem.span(frame.site.file.obj.toPtr([*:0]const u8))
            else
                input_path orelse "<input>";
            writer.print("  at {s} ({s}:{d}:{d})\n", .{
                name,
                path,
                frame.site.line,
                frame.site.col,
            }) catch std.process.exit(1);
            continue;
        }
        if (!frame.site.source.isNil()) {
            if (rt.dfsNodeLocation(frame.site.source, frame.site.idx)) |loc| {
                const path: []const u8 = if (loc.file) |file| std.mem.span(file) else input_path orelse "<input>";
                writer.print("  at {s} ({s}:{d}:{d})\n", .{ name, path, loc.line, loc.col }) catch std.process.exit(1);
                continue;
            }
        }
        writer.print("  at {s}\n", .{name}) catch std.process.exit(1);
    }
    writer.flush() catch std.process.exit(1);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // --no-bytecode-opts disables EVERY register-VM compiler optimization
    // (Runtime.compiler_opts.global = false): no arith fast path, no case-eq
    // specialization, no type joins/narrowing, no let-binding types, no
    // small-immediate mov_i64, no constant seeding.
    var no_bytecode_opts = false;
    // --repl-no-highlight disables REPL query highlighting entirely
    // (no tree-sitter engine, plain history text); useful for
    // non-interactive pipelines and dumb terminals.
    var use_highlight = true;
    var options_enabled = true;
    var literal_input = false;
    var file_path: ?[]const u8 = null;
    var arg_idx: usize = 1;
    while (arg_idx < args.len) : (arg_idx += 1) {
        const arg = args[arg_idx];
        if (options_enabled) {
            if (std.mem.eql(u8, arg, "--")) {
                options_enabled = false;
                continue;
            }
            if (std.mem.eql(u8, arg, "--help")) {
                try printUsage(io);
                return;
            }
            if (std.mem.eql(u8, arg, "-h")) {
                try printUsage(io);
                return;
            }
            if (std.mem.eql(u8, arg, "--regvm")) {
                continue;
            }
            if (std.mem.eql(u8, arg, "--no-bytecode-opts")) {
                no_bytecode_opts = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--repl-no-highlight")) {
                use_highlight = false;
                continue;
            }
            if (arg.len > 0) {
                if (arg[0] == '-') {
                    if (!std.mem.eql(u8, arg, "-")) {
                        exitWithCliError("skript: unknown option: {s}\n", io, .{arg});
                    }
                }
            }
        }
        if (file_path != null) {
            exitWithCliError("skript: expected at most one input\n", io, .{});
        }
        file_path = arg;
        literal_input = !options_enabled;
    }

    if (file_path == null) {
        return printUsage(io);
    }

    // SAFETY: immediately passed as buffer to stdin reader
    var stdin_buf: [1024]u8 = undefined;
    const stdin_file = std.Io.File.stdin();
    var stdin_reader = stdin_file.reader(io, &stdin_buf);
    const stdin = &stdin_reader.interface;

    // SAFETY: immediately passed as buffer to stdout writer
    var stdout_buf: [4096]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    if (!literal_input and std.mem.eql(u8, file_path.?, "repl")) {
        return repl.appRepl(alloc, init.arena.allocator(), io, init, stdout, use_highlight);
    }

    var rt = try skript.Runtime.init(alloc, io);
    defer rt.deinit();
    rt.stdin_reader = stdin;
    rt.stdout = stdout;
    if (no_bytecode_opts) rt.compiler_opts.global = false;

    var src: []const u8 = "(+ 1 2)";
    if (file_path) |path| {
        if (!literal_input and std.mem.eql(u8, path, "-")) {
            var writer = std.Io.Writer.Allocating.init(init.arena.allocator());
            _ = try stdin.streamRemaining(&writer.writer);
            src = writer.written();
        } else {
            const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
            defer file.close(io);
            const stat = try file.stat(io);
            var map = try file.createMemoryMap(io, .{ .protection = .{ .read = true }, .len = @intCast(stat.size) });
            defer map.destroy(io);
            src = try init.arena.allocator().dupe(u8, map.memory);
        }
    }
    // Files are implicitly modules. The main module keeps root_ns as its
    // namespace; give the process its file path (module_path) so its
    // relative loads resolve against the file's directory, and register the
    // main module in the registry so a loaded module that loads the
    // main file back is detected as a cycle.
    const canonical: ?[:0]u8 = if (file_path) |p|
        if (!literal_input and std.mem.eql(u8, p, "-"))
            null
        else
            std.Io.Dir.cwd().realPathFileAlloc(io, p, init.arena.allocator()) catch null
    else
        null;
    const proc = rt.spawnEvalWithNs(src, rt.root_ns, canonical) catch |err|
        exitWithRuntimeError(rt, skript.Value.err(err), .nil, canonical);
    if (canonical) |c| try rt.registerMainModule(c, proc);
    const res = rt.awaitProcess(proc) catch |err| exitWithRuntimeError(
        rt,
        if (proc.result.typ == skript.builtins.type_error) proc.result else skript.Value.err(err),
        proc.raised,
        canonical,
    );
    try stdout.print("=> {f} [regvm]\n", .{skript.intrinsics.print.FormatValue{ .runtime = rt, .value = res }});
    try stdout.flush();
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
    }
}
