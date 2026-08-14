const std = @import("std");
const skript = @import("skript");
const bench_core = @import("bench_core.zig");
const Runtime = skript.Runtime;

pub const BenchResult = struct {
    program: []const u8,
    reg_vm_us: u64 = 0,
    reg_code_size: usize = 0,
};

/// Run a program on the register VM.
/// If the register VM cannot compile the program (returns Unimplemented),
/// reg_vm_us is set to 0 and the function returns without error.
pub fn runBench(gpa: std.mem.Allocator, io: std.Io, program: []const u8) !BenchResult {
    var result: BenchResult = .{ .program = program };

    // --- Register VM ---
    // Phase B: spawnEval compiles on the host (readAll + analyzeData —
    // programs that cannot compile return Unimplemented, handled gracefully)
    // and dispatches a cooperative process; the await is what is timed.
    {
        var rt = try Runtime.init(gpa, io);
        defer rt.deinit();
        const proc = rt.spawnEval(program) catch |err| switch (err) {
            error.Unimplemented => {
                result.reg_vm_us = 0;
                return result;
            },
            else => |e| return e,
        };
        // spawnEval hides the compiled program, so the instruction count is no
        // longer visible here; the field is unused by the bench output.
        result.reg_code_size = 0;
        const start = std.Io.Timestamp.now(io, .awake);
        _ = try rt.awaitProcess(proc);
        const end = std.Io.Timestamp.now(io, .awake);
        const elapsed_ns = end.nanoseconds - start.nanoseconds;
        result.reg_vm_us = @as(u64, @intCast(elapsed_ns)) / 1000;
    }

    return result;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // SAFETY: immediately passed as buffer to stdout writer.
    var stdout_buf: [4096]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    if (args.len == 2 and std.mem.eql(u8, args[1], "--core-evolution")) {
        try bench_core.run(gpa, io, stdout);
        try stdout.flush();
        return;
    }

    if (args.len == 3 and std.mem.eql(u8, args[1], "--core-evolution-case")) {
        try bench_core.runCase(gpa, io, stdout, args[2], 0);
        try stdout.flush();
        return;
    }

    if (args.len == 4 and std.mem.eql(u8, args[1], "--core-evolution-profile")) {
        const repeats = try std.fmt.parseInt(usize, args[3], 10);
        if (repeats == 0) return error.InvalidArgument;
        try bench_core.runCase(gpa, io, stdout, args[2], repeats);
        try stdout.flush();
        return;
    }

    const programs = [_][]const u8{
        "(+ 1 2)",
        "(+ 1 (+ 2 3))",
        "(let ((x 5) (y 10)) (+ x y))",
        "(defn (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 10)",
    };

    for (programs) |prog| {
        const result = runBench(gpa, io, prog) catch |err| {
            try stdout.print("ERROR: {s}: {}\n", .{ prog, err });
            continue;
        };
        const reg_status = if (result.reg_vm_us > 0)
            result.reg_vm_us
        else
            0;
        const reg_label = if (result.reg_vm_us > 0) "us" else "N/A";
        try stdout.print("{s}: reg={d}{s}\n", .{
            result.program, reg_status, reg_label,
        });
    }

    try stdout.flush();
}
