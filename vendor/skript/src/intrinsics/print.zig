const std = @import("std");
const log = std.log.scoped(.print);

// Width-aware terminal-column measurement (vendored copy of zigzag's Unicode
// table — the same table the REPL's zz.measure uses).
const display_width = @import("../display_width.zig");

const skript = @import("../root.zig");
const Value = skript.Value;
const Object = skript.Object;
const Error = skript.Error;
const EvalContext = skript.EvalContext;
const FuncPtr = skript.FuncPtr;
const Runtime = skript.Runtime;
const Type = skript.data.Type;
const Closure = skript.data.Closure;

const intrin = @import("root.zig");
const tensor_mod = @import("tensor.zig");
const widget_mod = @import("widget.zig");

fn requireDisplayContext(ctx: *EvalContext) Error!void {
    try ctx.check();
    if (ctx.mode != .concrete or ctx.execution != .trusted) return error.Denied;
    if (ctx.effects.state_read != .allow or ctx.effects.io != .allow or
        ctx.effects.host != .allow or ctx.effects.unknown != .allow)
    {
        return error.Denied;
    }
}

fn requireFormatContext(ctx: *EvalContext) Error!void {
    try ctx.check();
    if (ctx.mode != .concrete or ctx.execution != .trusted) return error.Denied;
    if (ctx.effects.state_read != .allow or ctx.effects.unknown != .allow) {
        return error.Denied;
    }
}

pub fn write(ctx: *EvalContext, ns: Value, _: Value, args: []const Value) Error!Value {
    try requireDisplayContext(ctx);
    var scope = ctx.activate();
    defer scope.deinit();
    const rt = ctx.runtime;
    for (args) |arg| {
        const tag_val: u64 = @backingInt(arg.typ);
        const typ = if (tag_val <= skript.builtins.type_last_idx)
            rt.predefined_types.items[@as(usize, @intCast(tag_val))].*
        else
            arg.typ.toRef().deref(Type).*;
        _ = try ctx.apply(ns.unwrapNil() orelse rt.root_ns, typ.display, &.{arg});
    }
    return .{};
}

pub fn displayBuiltin(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try requireDisplayContext(ctx);
    const rt = ctx.runtime;
    var scope = ctx.activate();
    defer scope.deinit();
    var output = std.Io.Writer.Allocating.init(ctx.scratch);
    defer output.deinit();
    for (args) |arg| {
        try output.writer.print(
            "{f}",
            .{FormatValue{ .value = arg, .runtime = rt, .raw_strings = true }},
        );
    }
    try output.writer.flush();
    try ctx.writeAll(output.written());
    ctx.output.writer.flush() catch |err| log.err("flush failed: {any}", .{err});
    return .{};
}

pub const FormatFloat = struct {
    value: Value,
    pub fn format(self: FormatFloat, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const f = switch (self.value.typ) {
            skript.builtins.type_f8 => self.value.obj.tof64(),
            skript.builtins.type_f16 => @as(f64, @floatCast(self.value.obj.tof16())),
            skript.builtins.type_f32 => @as(f64, @floatCast(self.value.obj.tof32())),
            skript.builtins.type_f64 => self.value.obj.tof64(),
            else => return error.WriteFailed,
        };
        if (f == @round(f)) {
            try w.print("{d:.1}", .{f});
        } else {
            try w.print("{d}", .{f});
        }
    }
};

pub const FormatComplex = struct {
    value: Value,
    rt: *Runtime,
    pub fn format(self: FormatComplex, w: *std.Io.Writer) std.Io.Writer.Error!void {
        // SAFETY: set in every branch of the following switch
        var real: f64, var imag: f64 = .{ undefined, undefined };
        switch (self.value.typ) {
            skript.builtins.type_c8 => return error.WriteFailed,
            skript.builtins.type_c16 => {
                const val = self.value.obj.as([4]f16);
                real = @floatCast(val[0]);
                imag = @floatCast(val[1]);
            },
            skript.builtins.type_c32 => {
                const val = self.value.obj.as([2]f32);
                real = @floatCast(val[0]);
                imag = @floatCast(val[1]);
            },
            skript.builtins.type_c64 => {
                const pair = self.value.obj.toRef().deref([2]f64).*;
                real = pair[0];
                imag = pair[1];
            },
            else => return error.WriteFailed,
        }
        if (imag < 0.0) {
            try w.print("{f}{f}i", .{ FormatFloat{ .value = .f64(real) }, FormatFloat{ .value = .f64(imag) } });
        } else {
            try w.print("{f}+{f}i", .{ FormatFloat{ .value = .f64(real) }, FormatFloat{ .value = .f64(imag) } });
        }
    }
};

fn widgetLookup(rt: *Runtime, map: anytype, name: []const u8) ?Value {
    const sym = rt.store.getsym(name) catch return null;
    const key: skript.data.MapKey = .{
        .typ = @intCast(@backingInt(skript.builtins.type_keyword)),
        .obj = Value.keyword(sym).obj,
    };
    return map.get(key);
}

fn widgetOptionWord(v: Value) ?[]const u8 {
    if (v.typ != skript.builtins.type_symbol and v.typ != skript.builtins.type_keyword) return null;
    return v.obj.toPtr(skript.Sym).*;
}

/// Canonical encoding has no slots for extra map entries, so reject them to
/// preserve ordinary map data.
fn widgetMapKeysValid(kind: widget_mod.WidgetKind, map: anytype) bool {
    const keyword_tag: u8 = @intCast(@backingInt(skript.builtins.type_keyword));
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (key.typ != keyword_tag) return false;
        const name = key.obj.toPtr(skript.Sym).*;
        if (std.mem.eql(u8, name, "type") or std.mem.eql(u8, name, "data")) continue;
        switch (kind) {
            .image => {
                if (std.mem.eql(u8, name, "colorspace") or std.mem.eql(u8, name, "colormap"))
                    continue;
            },
            .video => if (std.mem.eql(u8, name, "fps")) continue,
            .audio => if (std.mem.eql(u8, name, "rate")) continue,
        }
        return false;
    }
    return true;
}

fn formatWidgetData(
    w: *std.Io.Writer,
    kind: widget_mod.WidgetKind,
    holder: tensor_mod.TensorHolder,
) std.Io.Writer.Error!void {
    // Normalize samples at the wire boundary; never rewrite tensor storage.
    for (holder.data) |word| {
        switch (holder.inner) {
            .i64 => {
                var sample: i64 = @bitCast(word);
                if (kind != .audio) {
                    if (sample < 0) sample = 0;
                    if (sample > 255) sample = 255;
                }
                try w.print(" {d}", .{sample});
            },
            .f64 => {
                var sample: f64 = @bitCast(word);
                if (kind != .audio) {
                    if (!std.math.isFinite(sample)) {
                        sample = if (sample > 0.0) 1.0 else 0.0;
                    } else if (sample <= 0.0) {
                        sample = 0.0;
                    } else if (sample >= 1.0) {
                        sample = 1.0;
                    }
                }
                try w.print(" {f}", .{FormatFloat{ .value = .f64(sample) }});
            },
            else => unreachable,
        }
    }
}

/// Canonical widget encoding. Returns true when the map printed as a
/// widget; false means fall through to ordinary hash-order map printing.
fn formatWidgetMap(self: *const FormatValue, w: *std.Io.Writer, map: anytype) std.Io.Writer.Error!bool {
    const rt = self.runtime;
    const type_val = widgetLookup(rt, map, "type") orelse return false;
    if (type_val.typ != skript.builtins.type_keyword) return false;
    const kind = widget_mod.isWidgetType(type_val.obj.toPtr(skript.Sym).*) orelse return false;
    const data_val = widgetLookup(rt, map, "data") orelse return false;
    if (data_val.typ != skript.builtins.type_tensor) return false;
    const holder = data_val.obj.toRef().deref(tensor_mod.TensorHolder).*;
    if (!widgetMapKeysValid(kind, map)) return false;
    const metadata: widget_mod.Metadata = .{
        .colorspace = widgetLookup(rt, map, "colorspace"),
        .colormap = widgetLookup(rt, map, "colormap"),
        .fps = widgetLookup(rt, map, "fps"),
        .rate = widgetLookup(rt, map, "rate"),
    };
    widget_mod.validateWidgetMetadata(kind, holder, metadata) catch return false;

    switch (kind) {
        .image => {
            const single = holder.rank == 2 or holder.shape[2] == 1;
            var word: []const u8 = if (single) "gray" else "rgb";
            if (metadata.colormap) |value| word = widgetOptionWord(value) orelse return false;
            if (metadata.colorspace) |value| word = widgetOptionWord(value) orelse return false;
            try w.print("(widget image", .{});
            for (holder.shape) |d| try w.print(" {d}", .{d});
            if (holder.rank == 2) try w.print(" 1", .{});
            try w.print(" {s}", .{word});
            try formatWidgetData(w, kind, holder);
            try w.writeAll(")");
            return true;
        },
        .video => {
            try w.print("(widget video", .{});
            for (holder.shape) |d| try w.print(" {d}", .{d});
            if (holder.rank == 3) try w.print(" 1", .{});
            const fps = if (metadata.fps) |value| value.obj.toInt(i64) else 30;
            try w.print(" {d}", .{fps});
            try formatWidgetData(w, kind, holder);
            try w.writeAll(")");
            return true;
        },
        .audio => {
            try w.print("(widget audio", .{});
            if (holder.rank == 1) {
                try w.print(" 1 {d}", .{holder.shape[0]});
            } else {
                for (holder.shape) |d| try w.print(" {d}", .{d});
            }
            const rate = if (metadata.rate) |value| value.obj.toInt(i64) else 44100;
            try w.print(" {d}", .{rate});
            try formatWidgetData(w, kind, holder);
            try w.writeAll(")");
            return true;
        },
    }
}

pub const FormatValue = struct {
    value: Value,
    runtime: *Runtime,
    /// Pretty mode (REPL answers): tensors render as the classical nested
    /// aligned matrix layout (BQN/UIUA/Julia style) — each rank-2 slice on
    /// its own lines with per-column alignment. `write`/`display` keep the
    /// compact single-line form.
    pretty: bool = false,
    /// R7RS `display` semantics: strings print RAW (no quotes, no escapes),
    /// so `(display "a\nb")` emits a real newline. `write` round-trips.
    raw_strings: bool = false,

    pub fn init(value: Value, rt: *Runtime) FormatValue {
        return .{ .value = value, .runtime = rt };
    }

    fn displayCons(self: *const FormatValue, w: *std.Io.Writer, arg: Value) std.Io.Writer.Error!void {
        const rt = self.runtime;
        try w.writeAll("(");
        var cur = arg;
        while (true) {
            const pair = cur.obj.toRef().deref([2]Value).*;
            try w.print("{f}", .{FormatValue{ .value = pair[0], .runtime = rt }});
            const cdr = pair[1];
            if (cdr.isNil()) {
                try w.writeAll(")");
                break;
            } else if (cdr.isCons()) {
                try w.writeAll(" ");
                cur = cdr;
            } else {
                try w.writeAll(" . ");
                try w.print("{f}", .{FormatValue{ .value = cdr, .runtime = rt }});
                try w.writeAll(")");
                break;
            }
        }
    }

    /// Print a tensor as nested `[...]` rows (round-trips with the reader's
    /// `[a b c]` desugar to `(stack a b c)`). Column-wise; `axis` selects
    /// the current dimension (0 = leading), `off` is this sub-tensor's flat
    /// data offset, `stride` is the element count per index unit at this
    /// axis. The LAST axis varies FASTEST in the flat data (stride_k =
    /// product of the FOLLOWING shapes), so consecutive elements of the
    /// last axis are 1 apart; the leading-axis slices (columns) are
    /// contiguous runs.
    fn displayTensor(
        self: *const FormatValue,
        w: *std.Io.Writer,
        holder: tensor_mod.TensorHolder,
        axis: usize,
        off: usize,
        stride: usize,
    ) std.Io.Writer.Error!void {
        const rt = self.runtime;
        const dim = holder.shape[axis];
        // A zero stride means a following axis is empty; no elements are read below it.
        const child_stride = if (axis + 1 == holder.rank or stride == 0)
            0
        else
            stride / holder.shape[axis + 1];
        try w.writeAll("[");
        for (0..dim) |i| {
            if (i != 0) try w.writeAll(" ");
            if (axis + 1 == holder.rank) {
                // Leaf: consecutive elements of the LAST axis are 1 apart.
                try w.print("{f}", .{FormatValue{
                    .value = tensor_mod.wordToValue(holder.inner, holder.data[off + i * stride]),
                    .runtime = rt,
                }});
            } else {
                try self.displayTensor(w, holder, axis + 1, off + i * stride, child_stride);
            }
        }
        try w.writeAll("]");
    }

    /// Uiua-style box rendering (REPL pretty) per lat.md (leading-axis
    /// theory): rank-1 = a vertical COLUMN (one element per line, capped at
    /// 16 rows with a "…" line), rank-2 = the TRANSPOSED matrix (rows =
    /// shape[1], columns = shape[0] — column-oriented: first column, then
    /// row), rank-3 = a STACK of matrices along axis 0 (planes separated by
    /// a dash rule spanning the content width), rank-4 = a MATRIX of
    /// submatrices (cells joined with "|" grid bars, a horizontal dash rule
    /// between grid rows). rank >= 5 falls back to nested aligned blocks.
    ///
    /// Alignment contract (width-aware — display columns, not bytes):
    ///   - per-column element widths inside each matrix; numerics right-
    ///     aligned, strings/symbols/keywords left-aligned; rows joined with
    ///     one space;
    ///   - a truncated-column " …" suffix goes on EVERY row so rows keep
    ///     equal width; truncated rows add a "…" line;
    ///   - rank-3: the per-column widths are taken across ALL planes (the
    ///     columns are the same logical columns); planes separated by a dash
    ///     rule;
    ///   - rank-4: each grid column's element widths = the max across the
    ///     cells in that grid column; cells joined with "|"; grid rows
    ///     separated by a dash rule;
    ///   - box frame (Uiua grid_fmt.rs geometry): content padded to W+4
    ///     (2 pre / 2 post); top "╭─"+blanks; first line "╷ "+content, rest
    ///     "  "+content, each with 2 trailing spaces; bottom (W+3) spaces
    ///     + "╯" at the last cell.
    /// Heavy computation is fine: this runs once per display.
    fn displayTensorPretty(
        self: *const FormatValue,
        w: *std.Io.Writer,
        holder: tensor_mod.TensorHolder,
    ) std.Io.Writer.Error!void {
        const rt = self.runtime;
        if (holder.rank >= 5) {
            // Fall back to nested aligned blocks (indent grows per rank).
            var stride: usize = 1;
            for (holder.shape[1..]) |d| stride *= d;
            try self.prettyLevel(w, holder, 0, 0, stride, 0, true);
            return;
        }
        var scratch = std.heap.ArenaAllocator.init(rt.store.backingAllocator());
        defer scratch.deinit();
        const alloc = scratch.allocator();

        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(alloc);
        var width: usize = 0;

        if (holder.rank == 1) {
            // VERTICAL COLUMN: one element per line (the last axis runs
            // down), capped at 16 rows with a "…" line.
            const n = holder.shape[0];
            const shown: usize = @min(n, 16);
            var ebuf: [256]u8 = undefined;
            for (0..shown) |i| {
                const s = self.elemStr(&ebuf, holder, holder.data[i]);
                // elemStr slices the shared ebuf — duplicate so every line
                // keeps its own text (a shared slice would render the LAST
                // element on every row).
                const owned = alloc.dupe(u8, s) catch return;
                lines.append(alloc, owned) catch return;
                width = @max(width, self.dispWidth(s));
            }
            if (n > shown) {
                lines.append(alloc, "…") catch return;
                width = @max(width, 1);
            }
        } else if (holder.rank == 2) {
            // TRANSPOSED visual: rows = shape[1], columns = shape[0]
            // (column-oriented: first column, then row). Column-wise
            // storage (the LAST axis varies fastest, columns contiguous):
            // cell(r,c) = flat[c*shape[1] + r] — row_stride 1,
            // col_stride shape[1].
            const rows = holder.shape[1];
            const cols = holder.shape[0];
            const cw = self.matrixColWidths(holder, 0, 1, holder.shape[1], rows, cols);
            const cell = self.matrixCell(alloc, holder, 0, 1, holder.shape[1], rows, cols, cw);
            for (cell.lines) |l| lines.append(alloc, l) catch break;
            width = cell.width;
        } else if (holder.rank == 3) {
            // A STACK of matrices along axis 0; each plane is the rank-2
            // visual (rows = shape[2], cols = shape[1]). Column-wise
            // storage: plane p's matrix T(p,·,·) reads transposed —
            // cell(r,c) = T(p,c,r) = flat[p*shape[1]*shape[2] +
            // c*shape[2] + r] — base p*s1*s2, row_stride 1,
            // col_stride shape[2]. Per-column widths across ALL planes (the
            // columns are the same logical columns); planes separated by a
            // dash rule spanning the content width.
            const planes = holder.shape[0];
            const rows = holder.shape[2];
            const cols = holder.shape[1];
            const row_stride: usize = 1;
            const col_stride: usize = holder.shape[2];
            const shown_planes: usize = @min(planes, 4);
            const plane_words = row_stride * col_stride * cols; // s1*s2
            var cw: [12]usize = @splat(0);
            for (0..shown_planes) |p| {
                const p_cw = self.matrixColWidths(
                    holder,
                    @intCast(p * plane_words),
                    row_stride,
                    col_stride,
                    rows,
                    cols,
                );
                for (0..12) |j| cw[j] = @max(cw[j], p_cw[j]);
            }
            for (0..shown_planes) |p| {
                if (p != 0) lines.append(alloc, self.dashRule(alloc, width)) catch return;
                const cell = self.matrixCell(
                    alloc,
                    holder,
                    @intCast(p * plane_words),
                    row_stride,
                    col_stride,
                    rows,
                    cols,
                    cw,
                );
                for (cell.lines) |l| lines.append(alloc, self.padTo(alloc, l, cell.width)) catch break;
                width = @max(width, cell.width);
            }
            if (planes > shown_planes) {
                lines.append(alloc, "…") catch return;
                width = @max(width, 1);
            }
        } else {
            // rank 4: a MATRIX of submatrices (grid). Grid COLUMNS are the
            // first leading axis, grid ROWS the second (per the storage-flip
            // verification: TL=0-5, TR=12-17, BL=6-11, BR=18-23 for
            // (reshape (iota 24) [2 2 2 3])); each cell is the stored block
            // T(i0,i1,·,·) rendered transposed: rows = shape[3],
            // cols = shape[2], cell(r,c) = T(i0,i1,c,r) =
            // flat[i0*s1*s2*s3 + i1*s2*s3 + c*s3 + r] — base
            // i0*s1*s2*s3 + i1*s2*s3, row_stride 1, col_stride shape[3].
            // Cells joined with "|" (grid bars); a horizontal dash rule
            // between grid rows. Each grid column's element widths = the max
            // across its cells.
            const a = holder.shape[0]; // grid columns
            const b = holder.shape[1]; // grid rows
            const rows = holder.shape[3];
            const cols = holder.shape[2];
            const row_stride: usize = 1;
            const col_stride: usize = holder.shape[3];
            const cell_words = @as(usize, holder.shape[2]) * holder.shape[3];
            const a_cap: usize = 3;
            const b_cap: usize = 3;
            const shown_a: usize = @min(a, a_cap);
            const shown_b: usize = @min(b, b_cap);

            if (shown_a > 0 and shown_b > 0) {
                var cells: [3][3]Cell = undefined;
                var grid_cw: [3][12]usize = @splat(@splat(0));
                for (0..shown_a) |i| {
                    for (0..shown_b) |j| {
                        const base = i * @as(usize, holder.shape[1]) * cell_words + j * cell_words;
                        const cw = self.matrixColWidths(holder, @intCast(base), row_stride, col_stride, rows, cols);
                        for (0..12) |k| grid_cw[j][k] = @max(grid_cw[j][k], cw[k]);
                    }
                }
                for (0..shown_a) |i| {
                    for (0..shown_b) |j| {
                        const base = i * @as(usize, holder.shape[1]) * cell_words + j * cell_words;
                        cells[i][j] = self.matrixCell(
                            alloc,
                            holder,
                            @intCast(base),
                            row_stride,
                            col_stride,
                            rows,
                            cols,
                            grid_cw[j],
                        );
                    }
                }
                const cell_h = cells[0][0].lines.len;
                for (0..shown_b) |j| {
                    if (j != 0) lines.append(alloc, self.dashRule(alloc, width)) catch return;
                    for (0..cell_h) |k| {
                        var line: std.ArrayList(u8) = .empty;
                        for (0..shown_a) |i| {
                            if (i != 0) line.append(alloc, '|') catch break;
                            line.appendSlice(alloc, cells[i][j].lines[k]) catch break;
                        }
                        const l = line.toOwnedSlice(alloc) catch continue;
                        lines.append(alloc, l) catch continue;
                        width = @max(width, self.dispWidth(l));
                    }
                }
            }
            if (a > shown_a or b > shown_b) {
                lines.append(alloc, "…") catch return;
            }
        }

        // Pad every line to the final width so the box right edge is straight.
        for (lines.items, 0..) |l, i| {
            const padded = self.padTo(alloc, l, width);
            lines.items[i] = padded;
        }
        if (lines.items.len == 0) lines.append(alloc, "") catch return;

        // Box frame per Uiua's src/grid_fmt.rs (pad_grid_center + outline;
        // reference: ~/projects/github-uiua-lang-uiua): the content is padded
        // to width+4 (2 pre, 2 post), the top is "╭─" + blanks (no dash row),
        // and the ╯ sits in the LAST cell of the padded grid — column W+3.
        try w.writeAll("╭─");
        for (0..width + 2) |_| try w.writeAll(" ");
        for (lines.items, 0..) |line, i| {
            try w.writeByte('\n');
            if (i == 0) try w.writeAll("╷ ") else try w.writeAll("  ");
            try w.writeAll(line);
            try w.writeAll("  ");
        }
        try w.writeByte('\n');
        for (0..width + 3) |_| try w.writeAll(" ");
        try w.writeAll("╯");
    }

    const Cell = struct {
        lines: []const []const u8,
        width: usize,
    };

    /// Display width of a string in terminal columns (width-aware).
    fn dispWidth(self: *const FormatValue, s: []const u8) usize {
        _ = self;
        return display_width.strWidth(s);
    }

    /// Format one element word into ebuf; returns the slice.
    fn elemStr(self: *const FormatValue, ebuf: []u8, holder: tensor_mod.TensorHolder, word: u64) []const u8 {
        const el = tensor_mod.wordToValue(holder.inner, word);
        return std.fmt.bufPrint(ebuf, "{f}", .{FormatValue{ .value = el, .runtime = self.runtime }}) catch ebuf;
    }

    /// Per-column element widths over a matrix window (visible rows/cols only).
    fn matrixColWidths(
        self: *const FormatValue,
        holder: tensor_mod.TensorHolder,
        base: usize,
        row_stride: usize,
        col_stride: usize,
        rows: usize,
        cols: usize,
    ) [12]usize {
        var widths: [12]usize = @splat(0);
        var ebuf: [256]u8 = undefined;
        const shown_rows: usize = @min(rows, 8);
        const shown_cols: usize = @min(cols, 12);
        for (0..shown_cols) |j| {
            for (0..shown_rows) |i| {
                const pos = base + i * row_stride + j * col_stride;
                const w = self.dispWidth(self.elemStr(&ebuf, holder, holder.data[pos]));
                widths[j] = @max(widths[j], w);
            }
        }
        return widths;
    }

    /// Build a matrix cell's lines with the GIVEN per-column widths. Numerics
    /// right-align, strings/symbols/keywords left-align; a truncated-column
    /// " …" suffix goes on every row (rows keep equal width); truncated rows
    /// append a "…" line.
    fn matrixCell(
        self: *const FormatValue,
        alloc: std.mem.Allocator,
        holder: tensor_mod.TensorHolder,
        base: usize,
        row_stride: usize,
        col_stride: usize,
        rows: usize,
        cols: usize,
        col_widths: [12]usize,
    ) Cell {
        var lines: std.ArrayList([]const u8) = .empty;
        var ebuf: [256]u8 = undefined;
        const shown_rows: usize = @min(rows, 8);
        const shown_cols: usize = @min(cols, 12);
        const numeric = holder.inner == .i64 or holder.inner == .f64;
        var width: usize = 0;
        for (0..shown_rows) |i| {
            var line: std.ArrayList(u8) = .empty;
            for (0..shown_cols) |j| {
                if (j != 0) line.append(alloc, ' ') catch break;
                const pos = base + i * row_stride + j * col_stride;
                const s = self.elemStr(&ebuf, holder, holder.data[pos]);
                const pad = col_widths[j] -| self.dispWidth(s);
                if (numeric) {
                    for (0..pad) |_| line.append(alloc, ' ') catch break;
                    line.appendSlice(alloc, s) catch break;
                } else {
                    line.appendSlice(alloc, s) catch break;
                    for (0..pad) |_| line.append(alloc, ' ') catch break;
                }
            }
            if (cols > shown_cols) line.appendSlice(alloc, " …") catch continue;
            const l = line.toOwnedSlice(alloc) catch continue;
            width = @max(width, self.dispWidth(l));
            lines.append(alloc, l) catch continue;
        }
        if (rows > shown_rows) lines.append(alloc, "…") catch return .{ .lines = &.{}, .width = width };
        return .{ .lines = lines.toOwnedSlice(alloc) catch &.{}, .width = width };
    }

    /// A horizontal rule of `width` dashes — the rank-3 plane separator and
    /// the rank-4 grid-row separator (spans the content width).
    fn dashRule(self: *const FormatValue, alloc: std.mem.Allocator, width: usize) []const u8 {
        _ = self;
        if (width == 0) return "";
        var rule: std.ArrayList(u8) = .empty;
        for (0..width) |_| rule.append(alloc, '-') catch return "";
        return rule.toOwnedSlice(alloc) catch "";
    }

    /// Pad `line` to `width` display columns with trailing spaces.
    fn padTo(self: *const FormatValue, alloc: std.mem.Allocator, line: []const u8, width: usize) []const u8 {
        const lw = self.dispWidth(line);
        if (lw >= width) return line;
        var out: std.ArrayList(u8) = .empty;
        out.appendSlice(alloc, line) catch return line;
        for (0..width - lw) |_| out.append(alloc, ' ') catch return line;
        return out.toOwnedSlice(alloc) catch line;
    }

    /// Render the slice starting at (axis, off, stride) with `depth` levels
    /// of indentation. `first` = this slice opens on the current line (its
    /// opening bracket follows directly after the caller's, no indent).
    /// Column-wise: `stride` is this axis's stride (product of the
    /// FOLLOWING shapes). An empty child keeps a zero stride because it has
    /// no elements to address.
    fn prettyLevel(
        self: *const FormatValue,
        w: *std.Io.Writer,
        holder: tensor_mod.TensorHolder,
        axis: usize,
        off: usize,
        stride: usize,
        depth: usize,
        first: bool,
    ) std.Io.Writer.Error!void {
        const rt = self.runtime;
        const dim = holder.shape[axis];
        const remaining = holder.rank - axis;

        if (remaining == 1) {
            // Leaf row: [e0 e1 …] on one line, truncated at 16 elements.
            if (!first) {
                try w.writeByte('\n');
                try self.indent(w, depth);
            }
            try w.writeAll("[");
            const shown: usize = @min(dim, 16);
            for (0..shown) |i| {
                if (i != 0) try w.writeByte(' ');
                try w.print("{f}", .{FormatValue{
                    .value = tensor_mod.wordToValue(holder.inner, holder.data[off + i * stride]),
                    .runtime = rt,
                }});
            }
            if (dim > shown) try w.writeAll(" …");
            try w.writeAll("]");
            return;
        }

        if (remaining == 2) {
            // Aligned matrix: rows on separate lines, per-column widths.
            // lat.md: the second-to-last axis renders HORIZONTALLY (columns),
            // the LAST axis VERTICALLY (rows) — rows = shape[axis+1],
            // cols = shape[axis]; row_stride 1, col_stride = this axis's
            // stride.
            const rows = holder.shape[axis + 1];
            const cols = dim;
            const row_cap: u64 = 8;
            const col_cap: u64 = 12;
            const shown_rows: usize = @min(rows, row_cap);
            const shown_cols: usize = @min(cols, col_cap);

            // Per-column max width over the visible window.
            var col_width: [col_cap]usize = @splat(0);
            var ebuf: [256]u8 = undefined;
            for (0..shown_cols) |j| {
                for (0..shown_rows) |i| {
                    const el = tensor_mod.wordToValue(
                        holder.inner,
                        holder.data[off + i * 1 + j * stride],
                    );
                    const s = std.fmt.bufPrint(&ebuf, "{f}", .{FormatValue{ .value = el, .runtime = rt }}) catch &ebuf;
                    col_width[j] = @max(col_width[j], s.len);
                }
            }

            if (!first) {
                try w.writeByte('\n');
                try self.indent(w, depth);
            }
            try w.writeAll("[");
            for (0..shown_rows) |i| {
                if (i != 0) {
                    try w.writeByte('\n');
                    try self.indent(w, depth + 1);
                }
                try w.writeAll("[");
                for (0..shown_cols) |j| {
                    if (j != 0) try w.writeByte(' ');
                    const el = tensor_mod.wordToValue(
                        holder.inner,
                        holder.data[off + i * 1 + j * stride],
                    );
                    const s = std.fmt.bufPrint(&ebuf, "{f}", .{FormatValue{ .value = el, .runtime = rt }}) catch &ebuf;
                    for (0..col_width[j] -| s.len) |_| try w.writeByte(' ');
                    try w.writeAll(s);
                }
                if (cols > shown_cols) try w.writeAll(" …");
                try w.writeAll("]");
            }
            if (rows > shown_rows) {
                try w.writeByte('\n');
                try self.indent(w, depth + 1);
                try w.writeAll("…");
            }
            try w.writeAll("]");
            return;
        }

        // remaining >= 3: leading-axis blocks, indented one space per level.
        if (!first) {
            try w.writeByte('\n');
            try self.indent(w, depth);
        }
        try w.writeAll("[");
        const block_cap: u64 = 4;
        const shown: usize = @min(dim, block_cap);
        const child_stride = if (stride == 0) 0 else stride / holder.shape[axis + 1];
        for (0..shown) |i| {
            try self.prettyLevel(
                w,
                holder,
                axis + 1,
                @intCast(off + @as(usize, @intCast(i * stride))),
                child_stride,
                depth + 1,
                i == 0,
            );
        }
        if (dim > shown) {
            try w.writeByte('\n');
            try self.indent(w, depth + 1);
            try w.writeAll("…");
        }
        try w.writeAll("]");
    }

    fn indent(self: *const FormatValue, w: *std.Io.Writer, depth: usize) std.Io.Writer.Error!void {
        _ = self;
        for (0..depth) |_| try w.writeByte(' ');
    }

    pub fn format(self: *const FormatValue, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const val = self.value;
        const rt = self.runtime;
        switch (val.typ) {
            skript.builtins.type_nil => try w.print("nil", .{}),
            skript.builtins.type_bool => try w.print("{s}", .{if (val.obj.toBool()) "#t" else "#f"}),
            skript.builtins.type_expr => {
                const datum = skript.intrinsics.symbolic.exprToDatum(rt.context(), .nil, .nil, &.{val}) catch
                    return error.WriteFailed;
                var nested = self.*;
                nested.value = datum;
                try nested.format(w);
            },
            // FIXME: proper f8
            skript.builtins.type_f8 => try w.print("{f}", .{FormatFloat{ .value = val }}),
            skript.builtins.type_f16 => try w.print("{f}", .{FormatFloat{ .value = val }}),
            skript.builtins.type_f32 => try w.print("{f}", .{FormatFloat{ .value = val }}),
            skript.builtins.type_f64 => try w.print("{f}", .{FormatFloat{ .value = val }}),
            skript.builtins.type_c8 => try w.print("{f}", .{FormatComplex{ .value = val, .rt = rt }}),
            skript.builtins.type_c16 => try w.print("{f}", .{FormatComplex{ .value = val, .rt = rt }}),
            skript.builtins.type_c32 => try w.print("{f}", .{FormatComplex{ .value = val, .rt = rt }}),
            skript.builtins.type_c64 => try w.print("{f}", .{FormatComplex{ .value = val, .rt = rt }}),
            skript.builtins.type_i8 => try w.print("{d}", .{val.obj.toInt(i8)}),
            skript.builtins.type_i16 => try w.print("{d}", .{val.obj.toInt(i16)}),
            skript.builtins.type_i32 => try w.print("{d}", .{val.obj.toInt(i32)}),
            skript.builtins.type_i64 => try w.print("{d}", .{val.obj.toInt(i64)}),
            skript.builtins.type_u8 => try w.print("{d}", .{val.obj.toInt(u8)}),
            skript.builtins.type_u16 => try w.print("{d}", .{val.obj.toInt(u16)}),
            skript.builtins.type_u32 => try w.print("{d}", .{val.obj.toInt(u32)}),
            skript.builtins.type_u64 => try w.print("{d}", .{val.obj.toInt(u64)}),
            skript.builtins.type_type => {
                const tag: u64 = @backingInt(val.obj);
                const typ_ptr: *const skript.Type = if (tag <= skript.builtins.type_last_idx)
                    rt.predefined_types.items[@as(usize, @intCast(tag))]
                else
                    val.obj.toRef().deref(skript.Type);
                try w.print("{s}", .{typ_ptr.name.toPtr(skript.Sym).*});
            },
            skript.builtins.type_symbol => try w.print("'{s}", .{val.obj.toPtr(skript.Sym).*}),
            skript.builtins.type_keyword => try w.print(":{s}", .{val.obj.toPtr(skript.Sym).*}),
            skript.builtins.type_string => {
                const s = val.obj.toPtr([*]u8);
                const raw = std.mem.sliceTo(s, 0);
                if (self.raw_strings) {
                    try w.print("{s}", .{raw});
                    return;
                }
                try w.print("\"", .{});
                for (raw) |ch| {
                    switch (ch) {
                        '"' => try w.print("\\\"", .{}),
                        '\\' => try w.print("\\\\", .{}),
                        '\n' => try w.print("\\n", .{}),
                        '\t' => try w.print("\\t", .{}),
                        '\r' => try w.print("\\r", .{}),
                        else => try w.print("{c}", .{ch}),
                    }
                }
                try w.print("\"", .{});
            },
            skript.builtins.type_bytevector => {
                const bytes = val.byteVectorBytes() catch return error.WriteFailed;
                try w.writeAll("#u8(");
                for (bytes, 0..) |byte, index| {
                    if (index != 0) try w.writeByte(' ');
                    try w.print("{d}", .{byte});
                }
                try w.writeByte(')');
            },
            skript.builtins.type_cons => {
                try self.displayCons(w, val);
            },
            skript.builtins.type_closure => {
                const closure = val.obj.toRef().deref(Closure);
                try w.print("<{*}", .{closure});
                if (closure.ir.len == 0) {
                    // Compiled closures carry no AST body.
                }
                try w.print(">", .{});
            },
            skript.builtins.type_ast => {
                const ptr = val.obj.toPtr(*skript.AstNodeRef);
                try w.print("{s}", .{ptr.span()});
            },
            skript.builtins.type_namespace => try w.print("<ns@0x{x:016}>", .{@backingInt(val.obj)}),
            skript.builtins.type_intrinsic => try w.print("<builtin@0x{x:08}>", .{@intFromPtr(val.obj.toPtr(FuncPtr))}),
            skript.builtins.type_pid => try w.print("<pid {d}>", .{val.obj.toPtr(*skript.scheduler.Process).pid}),
            skript.builtins.type_error => try w.print("<error {s}>", .{@errorName(val.errorCode())}),
            skript.builtins.type_ffifunc => try w.print("<ffifunc@0x{x:016}>", .{@backingInt(val.obj)}),
            skript.builtins.type_opaque => try w.print("<Opaque@0x{x:016}>", .{@backingInt(val.obj)}),
            skript.builtins.type_method => try w.print("<method@0x{x:016}>", .{@backingInt(val.obj)}),
            skript.builtins.type_map => {
                const holder = val.obj.toRef().deref(skript.data.MapHolder).*;
                if (try formatWidgetMap(self, w, holder.map)) return;
                try w.print("(map", .{});
                var it = holder.map.iterator();
                while (it.next()) |entry| {
                    try w.print(" {f} {f}", .{
                        FormatValue{ .value = skript.intrinsics.map.keyValue(entry.key_ptr.*), .runtime = rt },
                        FormatValue{ .value = entry.value_ptr.*, .runtime = rt },
                    });
                }
                try w.print(")", .{});
            },
            skript.builtins.type_tensor => {
                const holder = val.obj.toRef().deref(tensor_mod.TensorHolder).*;
                if (self.pretty) {
                    try self.displayTensorPretty(w, holder);
                } else {
                    // Column-wise: the leading axis is the slowest (its
                    // stride is the product of the following shapes).
                    var stride: usize = 1;
                    for (holder.shape[1..]) |d| stride *= d;
                    try self.displayTensor(w, holder, 0, 0, stride);
                }
            },
            else => {
                const tag: u64 = @backingInt(val.typ);
                const typ = if (tag <= skript.builtins.type_last_idx)
                    rt.predefined_types.items[@as(usize, @intCast(tag))].*
                else
                    val.typ.toRef().deref(skript.Type).*;
                const repr = rt.context().apply(.nil, typ.show, &.{val}) catch return error.WriteFailed;
                std.debug.assert(repr.isString());
                const str_start = repr.obj.toPtr([*]u8);
                const str = std.mem.sliceTo(str_start, 0);
                try w.print("{s}", .{str});
            },
        }
    }
};

pub fn debugFormatBuiltin(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try requireFormatContext(ctx);
    std.debug.assert(args.len == 1);
    const rt = ctx.runtime;
    const arg = args[0];

    var scope = ctx.activate();
    defer scope.deinit();
    var a_writer = std.Io.Writer.Allocating.init(ctx.scratch);
    defer a_writer.deinit();
    var writer = &a_writer.writer;
    try writer.print("{f}", .{FormatValue{ .runtime = rt, .value = arg }});
    try writer.flush();
    const str = a_writer.written();

    const slice = try rt.store.sym_alloc.allocSentinel(u8, str.len, 0);
    @memcpy(slice[0..str.len], str);
    return .string(Object.fromPtr(slice.ptr));
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
        std.testing.refAllDecls(FormatValue);
    }
}

test "pretty tensor formatting releases scratch before Runtime collection" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const tensor = try rt.evalString("(reshape (iota 4) (stack 2 2))");
    const raw_before = rt.store.stats().raw_allocations;
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try output.writer.print("{f}", .{FormatValue{
        .value = tensor,
        .runtime = rt,
        .pretty = true,
    }});
    try output.writer.flush();
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "3") != null);
    try std.testing.expectEqual(raw_before, rt.store.stats().raw_allocations);
    try rt.collect();
}

test "printing" {
    const alloc = std.testing.allocator;
    const runtime = try Runtime.init(alloc, std.testing.io);
    defer runtime.deinit();

    // FormatFloat branches on type
    {
        var buf_writer = std.Io.Writer.Allocating.init(alloc);
        defer buf_writer.deinit();
        try buf_writer.writer.print("{f}", .{FormatFloat{ .value = .f64(42.0) }});
        try buf_writer.writer.flush();
        try std.testing.expectEqualStrings("42.0", buf_writer.written());
    }
    {
        var buf_writer = std.Io.Writer.Allocating.init(alloc);
        defer buf_writer.deinit();
        try buf_writer.writer.print("{f}", .{FormatFloat{ .value = .f64(3.14) }});
        try buf_writer.writer.flush();
        try std.testing.expectEqualStrings("3.14", buf_writer.written());
    }
    {
        var buf_writer = std.Io.Writer.Allocating.init(alloc);
        defer buf_writer.deinit();
        try buf_writer.writer.print("{f}", .{FormatFloat{ .value = .f32(2.5) }});
        try buf_writer.writer.flush();
        try std.testing.expectEqualStrings("2.5", buf_writer.written());
    }
    {
        var buf_writer = std.Io.Writer.Allocating.init(alloc);
        defer buf_writer.deinit();
        try buf_writer.writer.print("{f}", .{FormatFloat{ .value = .f16(0.0) }});
        try buf_writer.writer.flush();
        try std.testing.expectEqualStrings("0.0", buf_writer.written());
    }

    // FormatValue uses FormatFloat for all float widths
    {
        var buf_writer = std.Io.Writer.Allocating.init(alloc);
        defer buf_writer.deinit();
        try buf_writer.writer.print("{f}", .{FormatValue{ .value = .f64(7.0), .runtime = runtime }});
        try buf_writer.writer.flush();
        try std.testing.expectEqualStrings("7.0", buf_writer.written());
    }
    {
        var buf_writer = std.Io.Writer.Allocating.init(alloc);
        defer buf_writer.deinit();
        try buf_writer.writer.print("{f}", .{FormatValue{ .value = .f32(1.5), .runtime = runtime }});
        try buf_writer.writer.flush();
        try std.testing.expectEqualStrings("1.5", buf_writer.written());
    }

    // FormatComplex formatting
    {
        const z = try intrin.complex.c32Cart(runtime.context(), .nil, .nil, &.{ .f32(1.0), .f32(2.0) });
        var buf_writer = std.Io.Writer.Allocating.init(alloc);
        defer buf_writer.deinit();
        try buf_writer.writer.print("{f}", .{FormatComplex{ .value = z, .rt = runtime }});
        try buf_writer.writer.flush();
        try std.testing.expectEqualStrings("1.0+2.0i", buf_writer.written());
    }
    {
        const z = try intrin.complex.c64Cart(runtime.context(), .nil, .nil, &.{ .f64(1.0), .f64(-2.0) });
        var buf_writer = std.Io.Writer.Allocating.init(alloc);
        defer buf_writer.deinit();
        try buf_writer.writer.print("{f}", .{FormatComplex{ .value = z, .rt = runtime }});
        try buf_writer.writer.flush();
        try std.testing.expectEqualStrings("1.0-2.0i", buf_writer.written());
    }
}
test "empty tensor axes print as nested brackets" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();

    try expectFormattedValue(runtime, try runtime.evalString("(reshape (iota 0) [1 0])"), "[[]]");
    try expectFormattedValue(runtime, try runtime.evalString("(reshape (iota 0) [2 1 0])"), "[[[]] [[]]]");
    try expectFormattedValue(runtime, try runtime.evalString("(reshape (iota 0) [0 2])"), "[]");
}

test "pretty formatting retains an empty rank-five inner axis" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const tensor = try runtime.evalString("(reshape (iota 0) [1 1 0 1 1])");

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try output.writer.print("{f}", .{FormatValue{
        .value = tensor,
        .runtime = runtime,
        .pretty = true,
    }});
    try output.writer.flush();
    try std.testing.expectEqualStrings("[[[]]]", output.written());
}

test "widget image prints canonically" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const t = try runtime.evalString("(reshape (stack 0 1 2 3) (stack 2 2))");
    const w = try widget_mod.image(runtime.context(), .nil, .nil, &.{t});
    var buf_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf_writer.deinit();
    try buf_writer.writer.print("{f}", .{FormatValue{ .value = w, .runtime = runtime }});
    try buf_writer.writer.flush();
    try std.testing.expectEqualStrings("(widget image 2 2 1 gray 0 1 2 3)", buf_writer.written());
}

test "widget video prints canonically" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const t = try runtime.evalString("(reshape (iota 8) (stack 2 2 2))");
    const w = try widget_mod.video(runtime.context(), .nil, .nil, &.{t});
    var buf_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf_writer.deinit();
    try buf_writer.writer.print("{f}", .{FormatValue{ .value = w, .runtime = runtime }});
    try buf_writer.writer.flush();
    try std.testing.expectEqualStrings("(widget video 2 2 2 1 30 0 1 2 3 4 5 6 7)", buf_writer.written());
}

test "widget audio prints canonically" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const s = try runtime.evalString("(iota 4)");
    const w = try widget_mod.audio(runtime.context(), .nil, .nil, &.{s});
    var buf_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf_writer.deinit();
    try buf_writer.writer.print("{f}", .{FormatValue{ .value = w, .runtime = runtime }});
    try buf_writer.writer.flush();
    try std.testing.expectEqualStrings("(widget audio 1 4 44100 0 1 2 3)", buf_writer.written());
}

fn expectFormattedValue(runtime: *Runtime, value: Value, expected: []const u8) !void {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try output.writer.print("{f}", .{FormatValue{ .value = value, .runtime = runtime }});
    try output.writer.flush();
    try std.testing.expectEqualStrings(expected, output.written());
}

fn expectOrdinaryMap(runtime: *Runtime, value: Value) !void {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try output.writer.print("{f}", .{FormatValue{ .value = value, .runtime = runtime }});
    try output.writer.flush();
    try std.testing.expect(std.mem.startsWith(u8, output.written(), "(map"));
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "(widget ") == null);
}

test "widget visual formatting clips samples without mutating tensors" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();

    const image_tensor = try runtime.evalString(
        "(reshape (stack 0.0 0.0 0.0 -0.25 0.5 1.25) [2 3])",
    );
    const image_holder = image_tensor.obj.toRef().deref(tensor_mod.TensorHolder);
    image_holder.data[0] = @bitCast(std.math.nan(f64));
    image_holder.data[1] = @bitCast(-std.math.inf(f64));
    image_holder.data[2] = @bitCast(std.math.inf(f64));
    const image_before: [6]u64 = image_holder.data[0..6].*;
    const image_widget = try widget_mod.image(ctx, .nil, .nil, &.{image_tensor});
    try expectFormattedValue(
        runtime,
        image_widget,
        "(widget image 2 3 1 gray 0.0 0.0 1.0 0.0 0.5 1.0)",
    );
    try std.testing.expectEqualSlices(u64, image_before[0..], image_holder.data);

    const video_tensor = try runtime.evalString("(reshape (stack 0.0 0.0 2.0) [1 1 3])");
    const video_holder = video_tensor.obj.toRef().deref(tensor_mod.TensorHolder);
    video_holder.data[0] = @bitCast(std.math.nan(f64));
    video_holder.data[1] = @bitCast(std.math.inf(f64));
    const video_before: [3]u64 = video_holder.data[0..3].*;
    const video_widget = try widget_mod.video(ctx, .nil, .nil, &.{video_tensor});
    try expectFormattedValue(
        runtime,
        video_widget,
        "(widget video 1 1 3 1 30 0.0 1.0 1.0)",
    );
    try std.testing.expectEqualSlices(u64, video_before[0..], video_holder.data);

    const integer_tensor = try runtime.evalString("(reshape (stack -1 256) [1 2])");
    const integer_holder = integer_tensor.obj.toRef().deref(tensor_mod.TensorHolder);
    const integer_before: [2]u64 = integer_holder.data[0..2].*;
    const integer_widget = try widget_mod.image(ctx, .nil, .nil, &.{integer_tensor});
    try expectFormattedValue(
        runtime,
        integer_widget,
        "(widget image 1 2 1 gray 0 255)",
    );
    try std.testing.expectEqualSlices(u64, integer_before[0..], integer_holder.data);
}

test "widget formatting validates metadata before emitting a canonical prefix" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();

    const malformed = [_][]const u8{
        "(hash-map :type :video :data (reshape (iota 8) [2 2 2]) :fps 0)",
        "(hash-map :type :video :data (reshape (iota 8) [2 2 2]) :fps \"fast\")",
        "(hash-map :type :video :data (reshape (iota 16) [2 2 2 2]) :fps 30)",
        "(hash-map :type :video :data (reshape (iota 32) [2 2 2 2 2]) :fps 30)",
        "(hash-map :type :image :data (reshape (iota 4) [2 2]) :colormap :bogus)",
        "(hash-map :type :audio :data (iota 4) :rate -1)",
        "(hash-map :type :audio :data (reshape (iota 33) [33 1]) :rate 44100)",
    };
    for (malformed) |source| {
        try expectOrdinaryMap(runtime, try runtime.evalString(source));
    }
}

test "widget maps with extra keys retain ordinary map data" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const map = try runtime.evalString(
        "(hash-map :type :image :data (reshape (iota 4) [2 2]) :extra 99)",
    );
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try output.writer.print("{f}", .{FormatValue{ .value = map, .runtime = runtime }});
    try output.writer.flush();
    try std.testing.expect(std.mem.startsWith(u8, output.written(), "(map"));
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "(widget ") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), ":extra") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "99") != null);
}

test "widget audio with nonfinite samples formats as an ordinary map" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const map = try runtime.evalString(
        "(hash-map :type :audio :data (stack 0.0 0.5) :rate 44100)",
    );
    const data = try intrin.map.get(
        runtime.context(),
        .nil,
        .nil,
        &.{ map, Value.keyword(try runtime.store.getsym("data")) },
    );
    data.obj.toRef().deref(tensor_mod.TensorHolder).data[1] =
        @bitCast(std.math.nan(f64));

    try expectOrdinaryMap(runtime, map);
}

test "widget image modes retain canonical positional metadata" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const grayscale = try runtime.evalString("(reshape (iota 2) [1 2])");
    const rgb = try runtime.evalString("(reshape (iota 3) [1 1 3])");
    const rgba = try runtime.evalString("(reshape (iota 4) [1 1 4])");

    try expectFormattedValue(
        runtime,
        try widget_mod.image(ctx, .nil, .nil, &.{grayscale}),
        "(widget image 1 2 1 gray 0 1)",
    );
    try expectFormattedValue(
        runtime,
        try widget_mod.image(ctx, .nil, .nil, &.{rgb}),
        "(widget image 1 1 3 rgb 0 1 2)",
    );
    try expectFormattedValue(
        runtime,
        try widget_mod.image(ctx, .nil, .nil, &.{rgba}),
        "(widget image 1 1 4 rgb 0 1 2 3)",
    );
}
