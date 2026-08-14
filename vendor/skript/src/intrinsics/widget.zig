const std = @import("std");

const skript = @import("../root.zig");
const tensor_mod = @import("tensor.zig");
const map_mod = @import("map.zig");

const Error = skript.Error;
const EvalContext = skript.EvalContext;
const Runtime = skript.Runtime;
const Value = skript.Value;
const b = skript.builtins;

/// Per-axis cap for image/video spatial dims; audio/video totals below.
const max_dim: u32 = 1024;
const max_audio_samples: usize = 2_000_000;
const max_video_elements: usize = 4_000_000;

fn chargeWork(ctx: *EvalContext, count: usize) Error!void {
    const count_u64 = std.math.cast(u64, count) orelse return error.Unsupported;
    try ctx.chargeWork(count_u64, 1, .transform);
}

pub const WidgetKind = enum { image, video, audio };

pub fn isWidgetType(name: []const u8) ?WidgetKind {
    if (std.mem.eql(u8, name, "image")) return .image;
    if (std.mem.eql(u8, name, "video")) return .video;
    if (std.mem.eql(u8, name, "audio")) return .audio;
    return null;
}

const Opt = enum { colorspace, colormap, fps, rate };

pub const Metadata = struct {
    colorspace: ?Value = null,
    colormap: ?Value = null,
    fps: ?Value = null,
    rate: ?Value = null,
};

fn optKey(name: []const u8) Error!Opt {
    if (std.mem.eql(u8, name, "colorspace")) return .colorspace;
    if (std.mem.eql(u8, name, "colormap")) return .colormap;
    if (std.mem.eql(u8, name, "fps")) return .fps;
    if (std.mem.eql(u8, name, "rate")) return .rate;
    return error.TypeMismatch;
}

/// Parse trailing `:key value` pairs. Only args[0] may be positional;
/// anything else non-keyword is an arity error. Returns the index of the
/// first kwarg, or args.len when no kwargs are present.
fn parseKwargs(args: []const Value, out: *std.EnumMap(Opt, Value)) Error!usize {
    var first: ?usize = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (args[i].typ != b.type_keyword) {
            if (i != 0) return error.ArityMismatch;
            continue;
        }
        if (first == null) first = i;
        if (i + 1 >= args.len) return error.ArityMismatch;
        const key = try optKey(args[i].obj.toPtr(skript.Sym).*);
        if (out.contains(key)) return error.ArityMismatch;
        out.put(key, args[i + 1]);
        i += 1;
    }
    return first orelse args.len;
}

fn kw(ctx: *EvalContext, name: []const u8) Error!Value {
    return Value.keyword(try ctx.runtime.store.getsym(name));
}

/// Accept a symbol or keyword option word (`'viridis` / `:viridis`);
/// anything else is a type error.
fn optionName(v: Value) Error![]const u8 {
    if (v.typ != b.type_symbol and v.typ != b.type_keyword) return error.TypeMismatch;
    return v.obj.toPtr(skript.Sym).*;
}

fn assertNumeric(h: tensor_mod.TensorHolder) Error!void {
    switch (h.inner) {
        .i64, .f64 => {},
        else => return error.TypeMismatch,
    }
}

fn assertSpatialCaps(shape: []const u32) Error!void {
    for (shape) |dimension| {
        if (dimension > max_dim) return error.Unsupported;
    }
}

const colormaps: []const []const u8 = &.{ "gray", "viridis", "plasma", "inferno", "magma" };

fn assertColormap(name: []const u8) Error!void {
    for (colormaps) |known| {
        if (std.mem.eql(u8, name, known)) return;
    }
    return error.TypeMismatch;
}

fn imageIsSingleChannel(holder: tensor_mod.TensorHolder) Error!bool {
    if (holder.rank == 2) return true;
    if (holder.rank != 3) return error.TypeMismatch;
    return switch (holder.shape[2]) {
        1 => true,
        3, 4 => false,
        else => error.TypeMismatch,
    };
}

fn validateRate(value: Value) Error!void {
    if (value.typ != b.type_i64) return error.TypeMismatch;
    const rate = value.obj.toInt(i64);
    if (rate < 8000 or rate > 96000) return error.Unsupported;
}

fn validateFps(value: Value) Error!void {
    if (value.typ != b.type_i64) return error.TypeMismatch;
    if (value.obj.toInt(i64) <= 0) return error.Unsupported;
}

fn validateAudioSamples(holder: tensor_mod.TensorHolder) Error!void {
    if (holder.inner != .f64) return;
    for (holder.data) |word| {
        if (!std.math.isFinite(@as(f64, @bitCast(word)))) return error.Unsupported;
    }
}

/// Validate all widget metadata and tensor constraints without allocating or
/// writing output. Callers may safely use the metadata after this succeeds.
pub fn validateWidgetMetadata(
    kind: WidgetKind,
    holder: tensor_mod.TensorHolder,
    metadata: Metadata,
) Error!void {
    try assertNumeric(holder);
    const rank = std.math.cast(usize, holder.rank) orelse return error.Unsupported;
    if (holder.shape.len != rank) return error.TypeMismatch;
    if (holder.data.len == 0) return error.TypeMismatch;

    switch (kind) {
        .image => {
            const single = try imageIsSingleChannel(holder);
            try assertSpatialCaps(holder.shape[0..2]);
            if (metadata.fps != null or metadata.rate != null) return error.TypeMismatch;
            if (metadata.colormap) |value| {
                if (!single) return error.Unsupported;
                try assertColormap(try optionName(value));
            }
            if (metadata.colorspace) |value| {
                if (single) return error.Unsupported;
                const colorspace = try optionName(value);
                if (!std.mem.eql(u8, colorspace, "rgb")) return error.TypeMismatch;
            }
        },
        .video => {
            if (metadata.colorspace != null or metadata.colormap != null or metadata.rate != null)
                return error.TypeMismatch;
            if (holder.rank != 3 and holder.rank != 4) return error.TypeMismatch;
            try assertSpatialCaps(holder.shape[1..3]);
            if (holder.rank == 4) {
                switch (holder.shape[3]) {
                    1, 3, 4 => {},
                    else => return error.TypeMismatch,
                }
            }
            if (metadata.fps) |value| try validateFps(value);
            if (holder.data.len > max_video_elements) return error.Unsupported;
        },
        .audio => {
            if (metadata.colorspace != null or metadata.colormap != null or metadata.fps != null)
                return error.TypeMismatch;
            if (holder.rank != 1 and holder.rank != 2) return error.TypeMismatch;
            if (holder.rank == 2 and (holder.shape[0] < 1 or holder.shape[0] > 32))
                return error.Unsupported;
            if (metadata.rate) |value| try validateRate(value);
            if (holder.data.len > max_audio_samples) return error.Unsupported;
            try validateAudioSamples(holder);
        },
    }
}

/// `(image t :colormap 'viridis)` — rank-2 gray or rank-3 HxWxC with
/// C in 1/3/4. Single-channel takes `:colormap`, multi-channel takes
/// `:colorspace`; anything else is an error.
pub fn image(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len == 0) return error.ArityMismatch;
    if (args[0].typ != b.type_tensor) return error.TypeMismatch;
    const data = args[0];
    const h = data.obj.toRef().deref(tensor_mod.TensorHolder).*;

    try assertNumeric(h);
    if (h.data.len == 0) return error.TypeMismatch;
    try chargeWork(ctx, h.data.len);
    var opts: std.EnumMap(Opt, Value) = .init(.{});
    _ = try parseKwargs(args, &opts);
    try validateWidgetMetadata(.image, h, .{
        .colorspace = opts.get(.colorspace),
        .colormap = opts.get(.colormap),
        .fps = opts.get(.fps),
        .rate = opts.get(.rate),
    });

    const single = try imageIsSingleChannel(h);
    var colormap: []const u8 = "gray";
    if (opts.get(.colormap)) |v| colormap = try optionName(v);
    var colorspace: []const u8 = "rgb";
    if (opts.get(.colorspace)) |v| colorspace = try optionName(v);

    const k_type = try kw(ctx, "type");
    const v_image = try kw(ctx, "image");
    const k_data = try kw(ctx, "data");
    if (single) {
        const k_colormap = try kw(ctx, "colormap");
        const v_colormap = try kw(ctx, colormap);
        return map_mod.create(ctx, .nil, .nil, &.{ k_type, v_image, k_data, data, k_colormap, v_colormap });
    }
    const k_colorspace = try kw(ctx, "colorspace");
    const v_colorspace = try kw(ctx, colorspace);
    return map_mod.create(ctx, .nil, .nil, &.{ k_type, v_image, k_data, data, k_colorspace, v_colorspace });
}

/// `(video t :fps 30)` — rank 3 or rank 4 F/H/W[ C], total elements at
/// most 4M. Only `:fps` is accepted.
pub fn video(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len == 0) return error.ArityMismatch;
    if (args[0].typ != b.type_tensor) return error.TypeMismatch;
    const data = args[0];
    const h = data.obj.toRef().deref(tensor_mod.TensorHolder).*;

    try assertNumeric(h);
    if (h.data.len == 0) return error.TypeMismatch;
    try chargeWork(ctx, h.data.len);
    var opts: std.EnumMap(Opt, Value) = .init(.{});
    _ = try parseKwargs(args, &opts);
    try validateWidgetMetadata(.video, h, .{
        .colorspace = opts.get(.colorspace),
        .colormap = opts.get(.colormap),
        .fps = opts.get(.fps),
        .rate = opts.get(.rate),
    });

    const fps = opts.get(.fps) orelse Value.i64(30);
    const k_type = try kw(ctx, "type");
    const v_video = try kw(ctx, "video");
    const k_data = try kw(ctx, "data");
    const k_fps = try kw(ctx, "fps");
    return map_mod.create(ctx, .nil, .nil, &.{ k_type, v_video, k_data, data, k_fps, fps });
}

/// `(audio s :rate 44100)` — rank-1 mono or rank-2 multi-channel numeric
/// tensor, at most 2M samples. Only `:rate` is accepted. Non-finite
/// samples are refused (image/video clip them instead).
pub fn audio(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len == 0) return error.ArityMismatch;
    if (args[0].typ != b.type_tensor) return error.TypeMismatch;
    const data = args[0];
    const h = data.obj.toRef().deref(tensor_mod.TensorHolder).*;

    try assertNumeric(h);
    if (h.data.len == 0) return error.TypeMismatch;
    try chargeWork(ctx, h.data.len);
    var opts: std.EnumMap(Opt, Value) = .init(.{});
    _ = try parseKwargs(args, &opts);
    try validateWidgetMetadata(.audio, h, .{
        .colorspace = opts.get(.colorspace),
        .colormap = opts.get(.colormap),
        .fps = opts.get(.fps),
        .rate = opts.get(.rate),
    });

    const rate = opts.get(.rate) orelse Value.i64(44100);
    const k_type = try kw(ctx, "type");
    const v_audio = try kw(ctx, "audio");
    const k_data = try kw(ctx, "data");
    const k_rate = try kw(ctx, "rate");
    return map_mod.create(ctx, .nil, .nil, &.{ k_type, v_audio, k_data, data, k_rate, rate });
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
    }
}

test "widget isWidgetType recognizes constructors" {
    try std.testing.expectEqual(WidgetKind.image, isWidgetType("image").?);
    try std.testing.expectEqual(WidgetKind.video, isWidgetType("video").?);
    try std.testing.expectEqual(WidgetKind.audio, isWidgetType("audio").?);
    try std.testing.expectEqual(@as(?WidgetKind, null), isWidgetType("map"));
}

test "widget image rejects bad rank" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const t = try runtime.evalString("(stack 1 2 3)");
    try std.testing.expectError(
        error.TypeMismatch,
        image(runtime.context(), .nil, .nil, &.{t}),
    );
}

test "widget image rejects bad channel count" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const t = try runtime.evalString("(reshape (iota 12) (stack 2 3 2))");
    try std.testing.expectError(
        error.TypeMismatch,
        image(runtime.context(), .nil, .nil, &.{t}),
    );
}

test "widget image rejects unknown option key" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const t = try runtime.evalString("(reshape (iota 16) (stack 4 4))");
    const bogus = Value.keyword(try runtime.store.getsym("bogus"));
    try std.testing.expectError(
        error.TypeMismatch,
        image(runtime.context(), .nil, .nil, &.{ t, bogus, .i64(1) }),
    );
}

test "widget image rejects oversize dims" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const t = try runtime.evalString("(reshape (iota 2050) (stack 1025 2))");
    try std.testing.expectError(
        error.Unsupported,
        image(runtime.context(), .nil, .nil, &.{t}),
    );
}

test "widget image rejects malformed kwargs" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const t = try runtime.evalString("(reshape (iota 16) (stack 4 4))");
    const k = Value.keyword(try runtime.store.getsym("colormap"));
    const v = Value.symbol(try runtime.store.getsym("gray"));
    // Dangling key with no value.
    try std.testing.expectError(error.ArityMismatch, image(ctx, .nil, .nil, &.{ t, k }));
    // Duplicate key.
    try std.testing.expectError(error.ArityMismatch, image(ctx, .nil, .nil, &.{ t, k, v, k, v }));
    // Non-tensor data.
    try std.testing.expectError(error.TypeMismatch, image(ctx, .nil, .nil, &.{.i64(42)}));
}

test "widget image rejects colormap on multi-channel data" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const t = try runtime.evalString("(reshape (iota 48) (stack 4 4 3))");
    const k = Value.keyword(try runtime.store.getsym("colormap"));
    const v = Value.symbol(try runtime.store.getsym("viridis"));
    try std.testing.expectError(
        error.Unsupported,
        image(runtime.context(), .nil, .nil, &.{ t, k, v }),
    );
}

test "widget image rejects colorspace on single-channel data" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const t = try runtime.evalString("(reshape (iota 16) (stack 4 4))");
    const k = Value.keyword(try runtime.store.getsym("colorspace"));
    const v = Value.symbol(try runtime.store.getsym("rgb"));
    try std.testing.expectError(
        error.Unsupported,
        image(runtime.context(), .nil, .nil, &.{ t, k, v }),
    );
}

test "widget image builds a map with type and data" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const t = try runtime.evalString("(reshape (iota 16) (stack 4 4))");
    const m = try image(ctx, .nil, .nil, &.{t});
    try std.testing.expectEqual(b.type_map, m.typ);
    const got_type = try map_mod.get(ctx, .nil, .nil, &.{ m, Value.keyword(try runtime.store.getsym("type")) });
    try std.testing.expectEqual(b.type_keyword, got_type.typ);
    try std.testing.expectEqualStrings("image", got_type.obj.toPtr(skript.Sym).*);
    const got_data = try map_mod.get(ctx, .nil, .nil, &.{ m, Value.keyword(try runtime.store.getsym("data")) });
    try std.testing.expectEqual(b.type_tensor, got_data.typ);
    const got_cmap = try map_mod.get(ctx, .nil, .nil, &.{ m, Value.keyword(try runtime.store.getsym("colormap")) });
    try std.testing.expectEqual(b.type_keyword, got_cmap.typ);
    try std.testing.expectEqualStrings("gray", got_cmap.obj.toPtr(skript.Sym).*);
}

test "widget image honors colormap" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const t = try runtime.evalString("(reshape (iota 16) (stack 4 4))");
    const k = Value.keyword(try runtime.store.getsym("colormap"));
    const v = Value.symbol(try runtime.store.getsym("viridis"));
    const m = try image(ctx, .nil, .nil, &.{ t, k, v });
    const got = try map_mod.get(ctx, .nil, .nil, &.{ m, Value.keyword(try runtime.store.getsym("colormap")) });
    try std.testing.expectEqualStrings("viridis", got.obj.toPtr(skript.Sym).*);
}

test "widget video defaults fps to 30" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const t = try runtime.evalString("(reshape (iota 24) (stack 2 3 4))");
    const m = try video(ctx, .nil, .nil, &.{t});
    try std.testing.expectEqual(b.type_map, m.typ);
    const got_type = try map_mod.get(ctx, .nil, .nil, &.{ m, Value.keyword(try runtime.store.getsym("type")) });
    try std.testing.expectEqualStrings("video", got_type.obj.toPtr(skript.Sym).*);
    const got_fps = try map_mod.get(ctx, .nil, .nil, &.{ m, Value.keyword(try runtime.store.getsym("fps")) });
    try std.testing.expectEqual(@as(i64, 30), got_fps.obj.toInt(i64));
}

test "widget video rejects rank-2 data" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const t = try runtime.evalString("(reshape (iota 16) (stack 4 4))");
    try std.testing.expectError(
        error.TypeMismatch,
        video(runtime.context(), .nil, .nil, &.{t}),
    );
}

test "widget video honors fps" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const t = try runtime.evalString("(reshape (iota 24) (stack 2 3 4))");
    const k = Value.keyword(try runtime.store.getsym("fps"));
    const m = try video(ctx, .nil, .nil, &.{ t, k, .i64(24) });
    const got = try map_mod.get(ctx, .nil, .nil, &.{ m, Value.keyword(try runtime.store.getsym("fps")) });
    try std.testing.expectEqual(@as(i64, 24), got.obj.toInt(i64));
}

test "widget audio defaults rate to 44100" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const s = try runtime.evalString("(iota 8)");
    const m = try audio(ctx, .nil, .nil, &.{s});
    try std.testing.expectEqual(b.type_map, m.typ);
    const got_type = try map_mod.get(ctx, .nil, .nil, &.{ m, Value.keyword(try runtime.store.getsym("type")) });
    try std.testing.expectEqualStrings("audio", got_type.obj.toPtr(skript.Sym).*);
    const got_rate = try map_mod.get(ctx, .nil, .nil, &.{ m, Value.keyword(try runtime.store.getsym("rate")) });
    try std.testing.expectEqual(@as(i64, 44100), got_rate.obj.toInt(i64));
}

test "widget audio rejects rank-3 data" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const s = try runtime.evalString("(reshape (iota 8) (stack 2 2 2))");
    try std.testing.expectError(
        error.TypeMismatch,
        audio(runtime.context(), .nil, .nil, &.{s}),
    );
}

test "widget audio refuses non-finite samples" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const s = try runtime.evalString("(stack 0.5 1.5)");
    s.obj.toRef().deref(tensor_mod.TensorHolder).data[0] = @bitCast(std.math.nan(f64));
    try std.testing.expectError(
        error.Unsupported,
        audio(runtime.context(), .nil, .nil, &.{s}),
    );
}

test "widget image constructor through eval" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const v = try runtime.evalString("(image (reshape (iota 16) [4 4]))");
    try std.testing.expectEqual(b.type_map, v.typ);
}

test "widget image type round-trip via map-get through eval" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const got = try runtime.evalString("(map-get (image (reshape (iota 16) [4 4])) :type)");
    try std.testing.expectEqual(b.type_keyword, got.typ);
    try std.testing.expectEqualStrings("image", got.obj.toPtr(skript.Sym).*);
}

test "widget image unknown keyword errors through eval" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    try std.testing.expectError(
        error.TypeMismatch,
        runtime.evalString("(image (reshape (iota 16) [4 4]) :bogus 1)"),
    );
}

test "widget image accepts grayscale RGB and RGBA layouts" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const grayscale = try runtime.evalString("(reshape (iota 4) [2 2])");
    const grayscale_channel = try runtime.evalString("(reshape (iota 4) [2 2 1])");
    const rgb = try runtime.evalString("(reshape (iota 12) [2 2 3])");
    const rgba = try runtime.evalString("(reshape (iota 16) [2 2 4])");

    try std.testing.expectEqual(b.type_map, (try image(ctx, .nil, .nil, &.{grayscale})).typ);
    try std.testing.expectEqual(
        b.type_map,
        (try image(ctx, .nil, .nil, &.{grayscale_channel})).typ,
    );
    try std.testing.expectEqual(b.type_map, (try image(ctx, .nil, .nil, &.{rgb})).typ);
    try std.testing.expectEqual(b.type_map, (try image(ctx, .nil, .nil, &.{rgba})).typ);
}

test "widget video accepts only supported ranks and channel layouts" {
    const runtime = try Runtime.initWithConfig(std.testing.allocator, std.testing.io, .{
        .max_heap_size = 4 * 1024 * 1024,
    });
    defer runtime.deinit();
    const many_frames = try runtime.evalString("(reshape (iota 1025) [1025 1 1])");
    const ctx = runtime.context();
    const grayscale = try runtime.evalString("(reshape (iota 8) [2 2 2])");
    const grayscale_channel = try runtime.evalString("(reshape (iota 8) [2 2 2 1])");
    const rgb = try runtime.evalString("(reshape (iota 24) [2 2 2 3])");
    const rgba = try runtime.evalString("(reshape (iota 32) [2 2 2 4])");
    const two_channels = try runtime.evalString("(reshape (iota 16) [2 2 2 2])");
    const rank_five = try runtime.evalString("(reshape (iota 32) [2 2 2 2 2])");

    try std.testing.expectEqual(b.type_map, (try video(ctx, .nil, .nil, &.{grayscale})).typ);
    try std.testing.expectEqual(
        b.type_map,
        (try video(ctx, .nil, .nil, &.{grayscale_channel})).typ,
    );
    try std.testing.expectEqual(b.type_map, (try video(ctx, .nil, .nil, &.{rgb})).typ);
    try std.testing.expectEqual(b.type_map, (try video(ctx, .nil, .nil, &.{rgba})).typ);
    try std.testing.expectEqual(b.type_map, (try video(ctx, .nil, .nil, &.{many_frames})).typ);
    try std.testing.expectError(
        error.TypeMismatch,
        video(ctx, .nil, .nil, &.{two_channels}),
    );
    try std.testing.expectError(error.TypeMismatch, video(ctx, .nil, .nil, &.{rank_five}));
}

test "widget video requires positive integer fps" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const frames = try runtime.evalString("(reshape (iota 8) [2 2 2])");
    const fps = Value.keyword(try runtime.store.getsym("fps"));

    for ([_]i64{ -1, 0 }) |invalid| {
        try std.testing.expectError(
            error.Unsupported,
            video(ctx, .nil, .nil, &.{ frames, fps, Value.i64(invalid) }),
        );
    }
    try std.testing.expectEqual(
        b.type_map,
        (try video(ctx, .nil, .nil, &.{ frames, fps, .i64(1) })).typ,
    );
    try std.testing.expectError(
        error.TypeMismatch,
        video(ctx, .nil, .nil, &.{ frames, fps, .f64(24.0) }),
    );
}

test "widget audio enforces browser rate and channel boundaries" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const mono = try runtime.evalString("(iota 4)");
    const max_channels = try runtime.evalString("(reshape (iota 32) [32 1])");
    const too_many_channels = try runtime.evalString("(reshape (iota 33) [33 1])");
    const rate = Value.keyword(try runtime.store.getsym("rate"));

    try std.testing.expectEqual(
        b.type_map,
        (try audio(ctx, .nil, .nil, &.{ mono, rate, .i64(8000) })).typ,
    );
    try std.testing.expectEqual(
        b.type_map,
        (try audio(ctx, .nil, .nil, &.{ max_channels, rate, .i64(96000) })).typ,
    );
    for ([_]i64{ -1, 0, 7999, 96001 }) |invalid| {
        try std.testing.expectError(
            error.Unsupported,
            audio(ctx, .nil, .nil, &.{ mono, rate, Value.i64(invalid) }),
        );
    }
    try std.testing.expectError(
        error.Unsupported,
        audio(ctx, .nil, .nil, &.{too_many_channels}),
    );
}
