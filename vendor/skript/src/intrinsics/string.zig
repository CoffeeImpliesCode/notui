const std = @import("std");
const log = std.log.scoped(.string);

const skript = @import("../root.zig");
const Value = skript.Value;
const Object = skript.Object;
const Sym = skript.Sym;
const Error = skript.Error;
const EvalContext = skript.EvalContext;
const Runtime = skript.Runtime;

const intrin = @import("root.zig");

/// Read the complete NUL-terminated bytes of a string Value.
fn valueStringBytes(ctx: *const EvalContext, value: Value) Error![:0]const u8 {
    return ctx.stringBytes(
        value.obj.toPtr([*:0]const u8),
        std.math.maxInt(usize),
        .native,
    );
}

/// Charge a linear byte traversal before executing it.
fn chargeBytes(ctx: *EvalContext, bytes: usize) Error!void {
    try ctx.chargeWork(@intCast(bytes), 1, .native);
}

/// Charge the bounded worst-case work of a substring search.
fn chargeSearch(ctx: *EvalContext, haystack_len: usize, needle_len: usize) Error!void {
    if (needle_len == 0) {
        try ctx.chargeWork(1, 1, .native);
        return;
    }
    try ctx.chargeWork(@intCast(haystack_len), @intCast(needle_len), .native);
}

/// Copy `bytes` into a Store string (the allocSlice pattern).
pub fn storeString(rt: *EvalContext, bytes: []const u8) Error!Value {
    try chargeBytes(rt, bytes.len);
    const alloc = try rt.runtime.store.allocSlice(u8, bytes.len + 1);
    @memcpy(alloc.slice[0..bytes.len], bytes);
    alloc.slice[bytes.len] = 0;
    return .string(Object.fromPtr(alloc.slice.ptr));
}

/// True when the value's type tag is one of the integer widths.
fn isIntType(t: Object) bool {
    return switch (t) {
        skript.builtins.type_i8,
        skript.builtins.type_i16,
        skript.builtins.type_i32,
        skript.builtins.type_i64,
        skript.builtins.type_u8,
        skript.builtins.type_u16,
        skript.builtins.type_u32,
        skript.builtins.type_u64,
        => true,
        else => false,
    };
}

/// `(string-append s ...)` — concatenate the byte slices in argument order;
/// `(string-append)` → `""`. O(total) work, one allocation.
pub fn append(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try rt.chargeWork(@intCast(args.len), 1, .native);
    const strings = try rt.scratch.alloc([:0]const u8, args.len);
    defer rt.scratch.free(strings);
    var total: usize = 0;
    for (args, strings) |argument, *string| {
        try intrin.typeAssert(argument, skript.builtins.type_string);
        string.* = try valueStringBytes(rt, argument);
        total += string.len;
    }
    try chargeBytes(rt, total);
    const alloc = try rt.runtime.store.allocSlice(u8, total + 1);
    var offset: usize = 0;
    for (strings) |string| {
        @memcpy(alloc.slice[offset .. offset + string.len], string);
        offset += string.len;
    }
    alloc.slice[total] = 0;
    return .string(Object.fromPtr(alloc.slice.ptr));
}
pub fn length(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_string);
    const string = try valueStringBytes(rt, args[0]);
    return .i64(@intCast(string.len));
}

const Cmp = enum { eq, ne, lt, gt, lte, gte };

fn compareAll(comptime mode: Cmp, rt: *EvalContext, args: []const Value) Error!Value {
    if (args.len < 2) return error.ArityMismatch;
    try rt.chargeWork(@intCast(args.len), 1, .native);
    for (args) |argument| try intrin.typeAssert(argument, skript.builtins.type_string);
    var previous = try valueStringBytes(rt, args[0]);
    for (args[1..]) |argument| {
        const current = try valueStringBytes(rt, argument);
        try chargeBytes(rt, @max(previous.len, current.len));
        const ok = switch (mode) {
            .eq => std.mem.eql(u8, previous, current),
            .ne => !std.mem.eql(u8, previous, current),
            else => blk: {
                const order = std.mem.order(u8, previous, current);
                break :blk switch (mode) {
                    .lt => order == .lt,
                    .gt => order == .gt,
                    .lte => order != .gt,
                    .gte => order != .lt,
                    else => unreachable,
                };
            },
        };
        if (!ok) return .false;
        previous = current;
    }
    return .true;
}

/// `(string=? s1 s2 ...)` — every adjacent pair equal.
pub fn eq(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    return compareAll(.eq, rt, args);
}

/// `(string!= s1 s2 ...)` — every adjacent pair unequal.
pub fn ne(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    return compareAll(.ne, rt, args);
}

/// `(string<? s1 s2 ...)` — strictly increasing adjacent pairs.
pub fn lt(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    return compareAll(.lt, rt, args);
}

/// `(string>? s1 s2 ...)` — strictly decreasing adjacent pairs.
pub fn gt(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    return compareAll(.gt, rt, args);
}

/// `(string<=? s1 s2 ...)` — non-strict increasing.
pub fn lte(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    return compareAll(.lte, rt, args);
}

/// `(string>=? s1 s2 ...)` — non-strict decreasing.
pub fn gte(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    return compareAll(.gte, rt, args);
}

const Case = enum { up, down };

/// Shared ASCII-only case mapping; every other byte copied unchanged.
/// Always returns a fresh string (strings are immutable).
fn caseImpl(comptime mode: Case, rt: *EvalContext, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_string);
    const s = try valueStringBytes(rt, args[0]);
    try chargeBytes(rt, s.len);
    const alloc = try rt.runtime.store.allocSlice(u8, s.len + 1);
    for (s, 0..) |ch, i| {
        alloc.slice[i] = switch (mode) {
            .up => if (ch >= 'a' and ch <= 'z') ch - 32 else ch,
            .down => if (ch >= 'A' and ch <= 'Z') ch + 32 else ch,
        };
    }
    alloc.slice[s.len] = 0;
    return .string(Object.fromPtr(alloc.slice.ptr));
}

/// `(string-upcase s)` — ASCII `a-z` → `A-Z`.
pub fn upcase(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    return caseImpl(.up, rt, args);
}

/// `(string-downcase s)` — ASCII `A-Z` → `a-z`.
pub fn downcase(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    return caseImpl(.down, rt, args);
}

/// `(string-find s sub)` — byte index of the first occurrence of `sub`, or
pub fn find(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_string);
    try intrin.typeAssert(args[1], skript.builtins.type_string);
    const s = try valueStringBytes(rt, args[0]);
    const sub = try valueStringBytes(rt, args[1]);
    try chargeSearch(rt, s.len, sub.len);
    const idx = std.mem.indexOf(u8, s, sub) orelse return .nil;
    return .i64(@intCast(idx));
}

/// `(string-replace s old new)` — replace all non-overlapping occurrences of
/// `old` (scanning left to right; after a match the scan resumes past it).
/// `old` empty → error.Unsupported; `old` absent → `s` returned unchanged.
pub fn replace(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 3);
    try intrin.typeAssert(args[0], skript.builtins.type_string);
    try intrin.typeAssert(args[1], skript.builtins.type_string);
    try intrin.typeAssert(args[2], skript.builtins.type_string);
    const s = try valueStringBytes(rt, args[0]);
    const old = try valueStringBytes(rt, args[1]);
    const new = try valueStringBytes(rt, args[2]);
    if (old.len == 0) return error.Unsupported;
    try chargeSearch(rt, s.len, old.len);
    if (std.mem.indexOf(u8, s, old) == null) return args[0];

    var count: usize = 0;
    var i: usize = 0;
    while (true) {
        try chargeSearch(rt, s.len - i, old.len);
        const pos = std.mem.findPos(u8, s, i, old) orelse break;
        count += 1;
        i = pos + old.len;
    }
    const out_len = s.len - count * old.len + count * new.len;
    try chargeBytes(rt, out_len);
    const alloc = try rt.runtime.store.allocSlice(u8, out_len + 1);
    var off: usize = 0;
    i = 0;
    while (true) {
        try chargeSearch(rt, s.len - i, old.len);
        const pos = std.mem.findPos(u8, s, i, old) orelse break;
        @memcpy(alloc.slice[off .. off + pos - i], s[i..pos]);
        off += pos - i;
        @memcpy(alloc.slice[off .. off + new.len], new);
        off += new.len;
        i = pos + old.len;
    }
    @memcpy(alloc.slice[off..out_len], s[i..]);
    alloc.slice[out_len] = 0;
    return .string(Object.fromPtr(alloc.slice.ptr));
}

/// `(string-split s sep)` — cons list of fields split at every `sep`;
/// empty fields are preserved. `sep` empty → error.Unsupported.
pub fn split(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_string);
    try intrin.typeAssert(args[1], skript.builtins.type_string);
    const s = try valueStringBytes(rt, args[0]);
    const sep = try valueStringBytes(rt, args[1]);
    if (sep.len == 0) return error.Unsupported;

    // Field count = 1 + separator count (trailing/leading empty fields kept).
    var n: usize = 1;
    var pos: usize = 0;
    while (true) {
        try chargeSearch(rt, s.len - pos, sep.len);
        const hit = std.mem.findPos(u8, s, pos, sep) orelse break;
        n += 1;
        pos = hit + sep.len;
    }

    const head_ref = try rt.runtime.store.create([2]Value);
    const head = Value.cons(head_ref.toObject());
    var cell = head_ref.deref([2]Value);
    pos = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try rt.chargeWork(1, 1, .native);
        try chargeSearch(rt, s.len - pos, sep.len);
        const end = std.mem.findPos(u8, s, pos, sep) orelse s.len;
        cell[0] = try storeString(rt, s[pos..end]);
        if (i + 1 < n) {
            const next_ref = try rt.runtime.store.create([2]Value);
            cell[1] = Value.cons(next_ref.toObject());
            cell = next_ref.deref([2]Value);
        } else {
            cell[1] = .nil;
        }
        pos = end + sep.len;
    }
    return head;
}

/// `(string-join strs sep)` — concatenate the elements of the proper cons
/// list `strs` with `sep` between consecutive elements. Empty list → `""`.
/// Improper list tail → error.Unsupported; non-string element →
/// error.TypeMismatch.
pub fn join(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    const list_value = args[0];
    if (list_value.typ != skript.builtins.type_cons and
        list_value.typ != skript.builtins.type_nil)
    {
        return error.TypeMismatch;
    }
    try intrin.typeAssert(args[1], skript.builtins.type_string);
    const separator = try valueStringBytes(rt, args[1]);

    var elements: std.ArrayList([:0]const u8) = .empty;
    defer elements.deinit(rt.scratch);
    var total: usize = 0;
    var current = list_value;
    while (current.typ == skript.builtins.type_cons) {
        try rt.chargeWork(1, 1, .native);
        const pair = current.obj.toRef().deref([2]Value).*;
        try intrin.typeAssert(pair[0], skript.builtins.type_string);
        const element = try valueStringBytes(rt, pair[0]);
        try elements.append(rt.scratch, element);
        total += element.len;
        current = pair[1];
    }
    if (current.typ != skript.builtins.type_nil) return error.Unsupported;
    if (elements.items.len > 0) total += (elements.items.len - 1) * separator.len;

    try rt.chargeWork(@intCast(elements.items.len), 1, .native);
    try chargeBytes(rt, total);
    const alloc = try rt.runtime.store.allocSlice(u8, total + 1);
    var offset: usize = 0;
    for (elements.items, 0..) |element, index| {
        if (index > 0) {
            @memcpy(alloc.slice[offset .. offset + separator.len], separator);
            offset += separator.len;
        }
        @memcpy(alloc.slice[offset .. offset + element.len], element);
        offset += element.len;
    }
    alloc.slice[total] = 0;
    return .string(Object.fromPtr(alloc.slice.ptr));
}

const Trim = enum { both, left, right };

/// Shared trim driver. Whitespace set is ASCII `" \t\n\r"` (same as
/// makeSymbol). No trimming needed → `s` returned unchanged (zero-copy).
fn trimImpl(comptime mode: Trim, rt: *EvalContext, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_string);
    const s = try valueStringBytes(rt, args[0]);
    try chargeBytes(rt, s.len);
    const trimmed = switch (mode) {
        .both => std.mem.trim(u8, s, " \t\n\r"),
        .left => std.mem.trimStart(u8, s, " \t\n\r"),
        .right => std.mem.trimEnd(u8, s, " \t\n\r"),
    };
    if (trimmed.len == s.len) return args[0];
    return storeString(rt, trimmed);
}

/// `(string-trim s)` — trim ASCII whitespace from both ends.
pub fn trim(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    return trimImpl(.both, rt, args);
}

/// `(string-trim-left s)` — trim ASCII whitespace from the left.
pub fn @"trim-left"(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    return trimImpl(.left, rt, args);
}

/// `(string-trim-right s)` — trim ASCII whitespace from the right.
pub fn @"trim-right"(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    return trimImpl(.right, rt, args);
}

const Pred = enum { includes, starts, ends };

fn predicateImpl(comptime kind: Pred, rt: *EvalContext, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_string);
    try intrin.typeAssert(args[1], skript.builtins.type_string);
    const s = try valueStringBytes(rt, args[0]);
    const sub = try valueStringBytes(rt, args[1]);
    switch (kind) {
        .includes => {
            try chargeSearch(rt, s.len, sub.len);
            return .bool(std.mem.indexOf(u8, s, sub) != null);
        },
        .starts, .ends => {
            try chargeBytes(rt, s.len);
            try chargeBytes(rt, sub.len);
        },
    }
    const ok = switch (kind) {
        .starts => std.mem.startsWith(u8, s, sub),
        .ends => std.mem.endsWith(u8, s, sub),
        .includes => unreachable,
    };
    return .bool(ok);
}

/// `(string-includes? s sub)` — is `sub` a byte substring of `s`?
pub fn @"includes?"(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    return predicateImpl(.includes, rt, args);
}

/// `(string-starts-with? s sub)` — is `sub` a byte prefix of `s`?
pub fn @"starts-with?"(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    return predicateImpl(.starts, rt, args);
}

/// `(string-ends-with? s sub)` — is `sub` a byte suffix of `s`?
pub fn @"ends-with?"(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    return predicateImpl(.ends, rt, args);
}

/// `(string-reverse s)` — reverse by UTF-8 codepoint, preserving valid UTF-8.
/// Invalid UTF-8 input → error.Unsupported. len ≤ 1 → `s` returned unchanged
pub fn reverse(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_string);
    const s = try valueStringBytes(rt, args[0]);
    try chargeBytes(rt, s.len);
    if (!std.unicode.utf8ValidateSlice(s)) return error.Unsupported;
    if (s.len <= 1) return args[0];
    // Place each codepoint at the tail of the output region in forward order,
    const alloc = try rt.runtime.store.allocSlice(u8, s.len + 1);
    var out: usize = s.len;
    const view = std.unicode.Utf8View.initUnchecked(s);
    var iter = view.iterator();
    while (iter.nextCodepointSlice()) |slice| {
        out -= slice.len;
        @memcpy(alloc.slice[out .. out + slice.len], slice);
    }
    alloc.slice[s.len] = 0;
    return .string(Object.fromPtr(alloc.slice.ptr));
}

/// `(substring s start end)` — codepoint slice `[start, end)`, 0-based,
/// end-exclusive, char-aware (UTF-8 codepoint indices). Invalid UTF-8 input →
/// error.Unsupported. Invariant `0 ≤ start ≤ end ≤ codepoint-len(s)`; violations
/// → error.Unsupported. Non-integer index → error.TypeMismatch.
pub fn substring(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 3);
    try intrin.typeAssert(args[0], skript.builtins.type_string);
    if (!isIntType(args[1].typ) or !isIntType(args[2].typ)) return error.TypeMismatch;
    const s = try valueStringBytes(rt, args[0]);
    try chargeBytes(rt, s.len);
    if (!std.unicode.utf8ValidateSlice(s)) return error.Unsupported;
    const start = intrin.convertFromValue(i64, args[1]);
    const end = intrin.convertFromValue(i64, args[2]);
    if (start < 0 or end < start) return error.Unsupported;

    // Count codepoints to bound the indices.
    try chargeBytes(rt, s.len);
    const view = std.unicode.Utf8View.initUnchecked(s);
    var n: i64 = 0;
    {
        var it = view.iterator();
        while (it.nextCodepoint()) |_| n += 1;
    }
    if (start > n or end > n) return error.Unsupported;

    // Translate codepoint indices to byte offsets; end == n means s.len.
    try chargeBytes(rt, s.len);
    var start_byte: usize = 0;
    var end_byte: usize = s.len;
    var iter = view.iterator();
    var cp: i64 = 0;
    var pos: usize = 0;
    while (iter.nextCodepointSlice()) |slice| {
        if (cp == start) start_byte = pos;
        if (cp == end) {
            end_byte = pos;
            break;
        }
        pos += slice.len;
        cp += 1;
    }
    if (start == n) start_byte = s.len; // empty tail (end must equal n too)
    return storeString(rt, s[start_byte..end_byte]);
}

/// `(string-byte-ref s k)` — the byte at index `k` as a u8 Value.
/// Require `0 ≤ k < len(s)`, else error.Unsupported. Non-integer `k` →
/// error.TypeMismatch.
pub fn @"byte-ref"(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_string);
    if (!isIntType(args[1].typ)) return error.TypeMismatch;
    const s = try valueStringBytes(rt, args[0]);
    try chargeBytes(rt, s.len);
    const k = intrin.convertFromValue(i64, args[1]);
    if (k < 0 or k >= @as(i64, @intCast(s.len))) return error.Unsupported;
    return .u8(s[@intCast(k)]);
}

const digits = "0123456789abcdef";

/// Format integer `v` (any width) in `radix` (2/8/10/16) into `buf`.
/// Signed negatives get a leading `-`; unsigned values render unsigned.
fn fmtInt(comptime T: type, buf: []u8, v: T, radix: u8) []const u8 {
    const info = @typeInfo(T).int;
    var mag: @Int(.unsigned, info.bits) = @bitCast(v);
    var neg = false;
    if (info.signedness == .signed and v < 0) {
        neg = true;
        mag = -%mag;
    }
    var idx = buf.len;
    while (mag > 0) {
        idx -= 1;
        buf[idx] = digits[@intCast(mag % radix)];
        mag /= radix;
    }
    if (idx == buf.len) { // v == 0
        idx -= 1;
        buf[idx] = '0';
    }
    if (neg) {
        idx -= 1;
        buf[idx] = '-';
    }
    return buf[idx..];
}

/// Render an integer Value in `radix` into a Store string.
fn intToStr(rt: *EvalContext, v: Value, radix: u8) Error!Value {
    try rt.chargeWork(65, 1, .native);
    var buf: [65]u8 = undefined;
    const out = switch (v.typ) {
        skript.builtins.type_i8 => fmtInt(i8, &buf, v.obj.toInt(i8), radix),
        skript.builtins.type_i16 => fmtInt(i16, &buf, v.obj.toInt(i16), radix),
        skript.builtins.type_i32 => fmtInt(i32, &buf, v.obj.toInt(i32), radix),
        skript.builtins.type_i64 => fmtInt(i64, &buf, v.obj.toInt(i64), radix),
        skript.builtins.type_u8 => fmtInt(u8, &buf, v.obj.toInt(u8), radix),
        skript.builtins.type_u16 => fmtInt(u16, &buf, v.obj.toInt(u16), radix),
        skript.builtins.type_u32 => fmtInt(u32, &buf, v.obj.toInt(u32), radix),
        skript.builtins.type_u64 => fmtInt(u64, &buf, v.obj.toInt(u64), radix),
        else => unreachable,
    };
    return storeString(rt, out);
}

/// Render a float Value into a Store string. f16/f32 render in their NATIVE
/// width (`{d}` shortest round-trip per width — FormatFloat's f64 cast would
/// render f32 3.14 as 3.140000104904175, breaking string->number round-trip);
/// f64 uses print.FormatFloat (integer-valued → `42.0`).
fn renderFloat(rt: *EvalContext, v: Value) Error!Value {
    try rt.chargeWork(64, 1, .native);
    var a_writer = std.Io.Writer.Allocating.init(rt.scratch);
    defer a_writer.deinit();
    switch (v.typ) {
        skript.builtins.type_f16 => try a_writer.writer.print("{d}", .{v.obj.tof16()}),
        skript.builtins.type_f32 => try a_writer.writer.print("{d}", .{v.obj.tof32()}),
        else => try a_writer.writer.print("{f}", .{intrin.print.FormatFloat{ .value = v }}),
    }
    try a_writer.writer.flush();
    return storeString(rt, a_writer.written());
}

/// Render a complex Value via print.FormatComplex (`1.0+2.0i`).
fn renderComplex(rt: *EvalContext, v: Value) Error!Value {
    try rt.chargeWork(128, 1, .native);
    var a_writer = std.Io.Writer.Allocating.init(rt.scratch);
    defer a_writer.deinit();
    try a_writer.writer.print("{f}", .{intrin.print.FormatComplex{ .value = v, .rt = rt.runtime }});
    try a_writer.writer.flush();
    return storeString(rt, a_writer.written());
}

/// `(number->string n [radix])` — radix ∈ {2, 8, 10, 16}, default 10.
/// Integers render in any radix (leading `-` for negatives, u64 unsigned).
/// Floats and complex render radix 10 only (else error.Unsupported) using
/// the print.FormatFloat / FormatComplex conventions. Non-numeric →
/// error.TypeMismatch.
pub fn @"number->string"(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len < 1 or args.len > 2) return error.ArityMismatch;
    var radix: u8 = 10;
    if (args.len == 2) {
        if (!isIntType(args[1].typ)) return error.TypeMismatch;
        const r = intrin.convertFromValue(i64, args[1]);
        if (r != 2 and r != 8 and r != 10 and r != 16) return error.Unsupported;
        radix = @intCast(r);
    }
    const v = args[0];
    switch (v.typ) {
        skript.builtins.type_i8,
        skript.builtins.type_i16,
        skript.builtins.type_i32,
        skript.builtins.type_i64,
        skript.builtins.type_u8,
        skript.builtins.type_u16,
        skript.builtins.type_u32,
        skript.builtins.type_u64,
        => return intToStr(rt, v, radix),
        skript.builtins.type_f8,
        skript.builtins.type_f16,
        skript.builtins.type_f32,
        skript.builtins.type_f64,
        => {
            if (radix != 10) return error.Unsupported;
            return renderFloat(rt, v);
        },
        skript.builtins.type_c16,
        skript.builtins.type_c32,
        skript.builtins.type_c64,
        => {
            if (radix != 10) return error.Unsupported;
            return renderComplex(rt, v);
        },
        else => return error.TypeMismatch,
    }
}

/// `(string->number s [radix])` — parse trimmed `s`, radix ∈ {2, 8, 10, 16},
/// default 10. Integer syntax in every radix; float syntax only in radix 10.
/// Parse failure (including i64 overflow) → `null`. No radix-prefix
/// auto-detection in v1. Bad radix → error.Unsupported.
pub fn @"string->number"(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len < 1 or args.len > 2) return error.ArityMismatch;
    try intrin.typeAssert(args[0], skript.builtins.type_string);
    var radix: u8 = 10;
    if (args.len == 2) {
        if (!isIntType(args[1].typ)) return error.TypeMismatch;
        const r = intrin.convertFromValue(i64, args[1]);
        if (r != 2 and r != 8 and r != 10 and r != 16) return error.Unsupported;
        radix = @intCast(r);
    }
    const raw = try valueStringBytes(rt, args[0]);
    try chargeBytes(rt, raw.len);
    const s = std.mem.trim(u8, raw, " \t\n\r");
    if (s.len == 0) return .nil;
    if (std.fmt.parseInt(i64, s, radix)) |i| {
        return .i64(i);
    } else |_| {}
    // Float syntax only in radix 10, and only when the string actually looks
    // like a float (contains '.'/'e'/'E' — the reader's own convention):
    // an all-digit integer literal that overflows i64 must yield null, not
    // silently parse as a float (spec: "i64 overflow → null").
    if (radix == 10 and std.mem.indexOfAny(u8, s, ".eE") != null) {
        if (std.fmt.parseFloat(f64, s)) |f| {
            return .f64(f);
        } else |_| {}
    }
    return .nil;
}

/// `(symbol->string sym)` — copy the interned symbol name (verbatim, no
/// quotes, no trimming) into a Store string.
pub fn @"from-symbol"(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_symbol);
    const name = args[0].obj.toPtr(Sym).*;
    return storeString(rt, name);
}

/// Byte length of a codepoint when UTF-8 encoded, validating that `v` is a
/// representable Unicode codepoint: in `1..=0x10FFFF` and not a surrogate.
/// `0` (NUL) is rejected — embedded NUL is not representable in the
/// NUL-terminated storage. Violations → error.Unsupported.
fn codepointLen(v: i64) Error!u3 {
    if (v <= 0 or v > 0x10FFFF) return error.Unsupported;
    var buf: [4]u8 = undefined;
    return std.unicode.utf8Encode(@intCast(v), &buf) catch return error.Unsupported;
}

/// `(string->list s)` — cons list of one UTF-8 codepoint value (i64) per
/// codepoint, in order. `(string->list "")` → `()`. Invalid UTF-8 →
/// error.Unsupported. Bridges strings to the collection algorithms.
pub fn @"to-list"(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_string);
    const s = try valueStringBytes(rt, args[0]);
    try chargeBytes(rt, s.len);
    if (!std.unicode.utf8ValidateSlice(s)) return error.Unsupported;

    var n: usize = 0;
    const view = std.unicode.Utf8View.initUnchecked(s);
    var iter = view.iterator();
    try chargeBytes(rt, s.len);
    while (iter.nextCodepoint()) |_| n += 1;
    if (n == 0) return .nil;

    const head_ref = try rt.runtime.store.create([2]Value);
    try rt.chargeWork(@intCast(n), 1, .native);
    const head = Value.cons(head_ref.toObject());
    var cell = head_ref.deref([2]Value);
    iter = view.iterator();
    var i: usize = 0;
    while (iter.nextCodepoint()) |cp| {
        cell[0] = .i64(@intCast(cp));
        if (i + 1 < n) {
            const next_ref = try rt.runtime.store.create([2]Value);
            cell[1] = Value.cons(next_ref.toObject());
            cell = next_ref.deref([2]Value);
        } else {
            cell[1] = .nil;
        }
        i += 1;
    }
    return head;
}

/// `(list->string elems)` — encode a proper cons list of integer codepoints
/// (any integer width) into a UTF-8 string. `(list->string (list))` → `""`.
/// Invalid codepoint (0, surrogate, >0x10FFFF) → error.Unsupported; non-integer
/// element → error.TypeMismatch; improper list tail → error.Unsupported.
pub fn @"from-list"(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    const list_val = args[0];
    if (list_val.typ != skript.builtins.type_cons and list_val.typ != skript.builtins.type_nil) {
        return error.TypeMismatch;
    }

    // Pass 1: validate every element and sum the encoded byte length.
    var total: usize = 0;
    var count: usize = 0;
    var cur = list_val;
    while (cur.typ == skript.builtins.type_cons) {
        try rt.chargeWork(1, 1, .native);
        const elem = cur.obj.toRef().deref([2]Value)[0];
        if (!isIntType(elem.typ)) return error.TypeMismatch;
        total += try codepointLen(intrin.convertFromValue(i64, elem));
        count += 1;
        cur = cur.obj.toRef().deref([2]Value)[1];
    }
    if (cur.typ != skript.builtins.type_nil) return error.Unsupported; // improper list

    // Pass 2: encode into one allocation.
    try chargeBytes(rt, total);
    const alloc = try rt.runtime.store.allocSlice(u8, total + 1);
    var off: usize = 0;
    cur = list_val;
    var idx: usize = 0;
    while (cur.typ == skript.builtins.type_cons and idx < count) {
        try rt.chargeWork(1, 1, .native);
        const pair = cur.obj.toRef().deref([2]Value).*;
        const cp: i64 = intrin.convertFromValue(i64, pair[0]);
        const n = try codepointLen(cp);
        const nsz: usize = n;
        const encoded_len = std.unicode.utf8Encode(
            @intCast(cp),
            alloc.slice[off .. off + nsz],
        ) catch return error.Unsupported;
        off += encoded_len;
        idx += 1;
        cur = pair[1];
    }
    alloc.slice[total] = 0;
    return .string(Object.fromPtr(alloc.slice.ptr));
}

/// Racket-style `~`-directive driver shared by `format`/`printf`. Literal
/// bytes (including `\n` already in the string) copy verbatim. Directive set:
/// `~a` display (strings raw), `~s`/`~v` write (strings quoted/escaped), `~n`/
/// `~%` newline (no arg), `~~` literal tilde (no arg). Unknown `~X` or a
/// dangling trailing `~` → error.Unsupported; a directive needing an argument
/// past the end of `args` → error.ArityMismatch. Extra args are ignored.
fn renderFormat(w: *std.Io.Writer, rt: *EvalContext, fmt: []const u8, args: []const Value) Error!void {
    try chargeBytes(rt, fmt.len);
    var i: usize = 0;
    var ai: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '~') {
            const start = i;
            while (i < fmt.len and fmt[i] != '~') i += 1;
            try w.writeAll(fmt[start..i]);
            continue;
        }
        i += 1;
        if (i >= fmt.len) return error.Unsupported;
        const d = fmt[i];
        i += 1;
        switch (d) {
            'a' => {
                if (ai >= args.len) return error.ArityMismatch;
                try w.print("{f}", .{intrin.print.FormatValue{
                    .value = args[ai],
                    .runtime = rt.runtime,
                    .raw_strings = true,
                }});
                ai += 1;
            },
            's', 'v' => {
                if (ai >= args.len) return error.ArityMismatch;
                try w.print("{f}", .{intrin.print.FormatValue{
                    .value = args[ai],
                    .runtime = rt.runtime,
                    .raw_strings = false,
                }});
                ai += 1;
            },
            'n', '%' => try w.writeByte('\n'),
            '~' => try w.writeByte('~'),
            else => return error.Unsupported,
        }
    }
}

/// `(format fmt args...)` — build a Store string from `~`-directives; no
/// output. `fmt` must be a string.
pub fn format(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len == 0) return error.ArityMismatch;
    try intrin.typeAssert(args[0], skript.builtins.type_string);
    const fmt = try valueStringBytes(rt, args[0]);
    var a_writer = std.Io.Writer.Allocating.init(rt.scratch);
    defer a_writer.deinit();
    try renderFormat(&a_writer.writer, rt, fmt, args[1..]);
    try a_writer.writer.flush();
    return storeString(rt, a_writer.written());
}

/// `(printf fmt args...)` — render like `format`, write the bytes through the
/// stdout path (mirroring `displayBuiltin`'s fallback), return `null`.
pub fn printf(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len == 0) return error.ArityMismatch;
    try intrin.typeAssert(args[0], skript.builtins.type_string);
    const fmt = try valueStringBytes(rt, args[0]);
    var a_writer = std.Io.Writer.Allocating.init(rt.scratch);
    defer a_writer.deinit();
    try renderFormat(&a_writer.writer, rt, fmt, args[1..]);
    try a_writer.writer.flush();
    const out = a_writer.written();

    try rt.writeAll(out);
    rt.output.writer.flush() catch |err| log.err("flush failed: {any}", .{err});
    return .{};
}

// --- runtime tests --- //

const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
fn newRt() !*Runtime {
    return Runtime.init(std.testing.allocator, std.testing.io);
}

fn strSlice(v: Value) []const u8 {
    return std.mem.sliceTo(v.obj.toPtr([*]u8), 0);
}

fn fstr(rt: *Runtime, v: Value) ![]const u8 {
    const s = try intrin.print.debugFormatBuiltin(rt.context(), .nil, .nil, &.{v});
    return strSlice(s);
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
    }
}

test "string-append" {
    var rt = try newRt();
    defer rt.deinit();
    try expectEqualStrings("abc", strSlice(try rt.evalString("(string-append \"a\" \"b\" \"c\")")));
    try expectEqualStrings("", strSlice(try rt.evalString("(string-append)")));
    try expectEqualStrings("x", strSlice(try rt.evalString("(string-append \"\" \"x\")")));
    try expectEqualStrings("abcde", strSlice(try rt.evalString("(string-append \"ab\" \"cd\" \"e\")")));
    try expectError(error.TypeMismatch, rt.evalString("(string-append \"foo\" 1)"));
    try expectError(error.TypeMismatch, rt.evalString("(string-append 1)"));
}

test "string-length" {
    var rt = try newRt();
    defer rt.deinit();
    const v = try rt.evalString("(string-length \"abc\")");
    try expectEqual(skript.builtins.type_i64, v.typ);
    try expectEqual(@as(i64, 3), v.obj.toInt(i64));
    try expectEqual(@as(i64, 0), (try rt.evalString("(string-length \"\")")).obj.toInt(i64));
    // é is 2 UTF-8 bytes: h(1) é(2) l l o = 6
    try expectEqual(@as(i64, 6), (try rt.evalString("(string-length \"héllo\")")).obj.toInt(i64));
    try expectError(error.TypeMismatch, rt.evalString("(string-length 42)"));
    try expectError(error.ArityMismatch, rt.evalString("(string-length \"a\" \"b\")"));
}

test "string comparisons" {
    var rt = try newRt();
    defer rt.deinit();
    try expect((try rt.evalString("(string=? \"abc\" \"abc\")")).obj.toBool());
    try expect(!(try rt.evalString("(string=? \"abc\" \"abd\")")).obj.toBool());
    try expect((try rt.evalString("(string=? \"a\" \"a\" \"a\")")).obj.toBool());
    try expect(!(try rt.evalString("(string=? \"a\" \"a\" \"b\")")).obj.toBool());
    try expect((try rt.evalString("(string<? \"abc\" \"abd\")")).obj.toBool());
    try expect(!(try rt.evalString("(string<? \"abc\" \"abc\")")).obj.toBool());
    try expect((try rt.evalString("(string<=? \"abc\" \"abc\" \"abd\")")).obj.toBool());
    try expect((try rt.evalString("(string>? \"b\" \"a\")")).obj.toBool());
    try expect((try rt.evalString("(string>=? \"b\" \"b\")")).obj.toBool());
    // string!= — adjacent-pair inequality (mirrors the eq pattern)
    try expect((try rt.evalString("(string!= \"abc\" \"abd\")")).obj.toBool());
    try expect(!(try rt.evalString("(string!= \"abc\" \"abc\")")).obj.toBool());
    try expect(!(try rt.evalString("(string!= \"a\" \"b\" \"b\")")).obj.toBool());
    try expectError(error.ArityMismatch, rt.evalString("(string<? \"a\")"));
    try expectError(error.TypeMismatch, rt.evalString("(string=? \"abc\" 1)"));
    try expectError(error.TypeMismatch, rt.evalString("(string!= \"abc\" 1)"));
}

test "string-upcase / string-downcase" {
    var rt = try newRt();
    defer rt.deinit();
    try expectEqualStrings("HELLO", strSlice(try rt.evalString("(string-upcase \"hello\")")));
    try expectEqualStrings("HELLO123!", strSlice(try rt.evalString("(string-upcase \"Hello123!\")")));
    try expectEqualStrings("", strSlice(try rt.evalString("(string-upcase \"\")")));
    try expectEqualStrings("hello", strSlice(try rt.evalString("(string-downcase \"HELLO\")")));
    // Non-ASCII unchanged, ASCII letters mapped (v1): Ä is C3 84, B/C → b/c
    try expectEqualStrings("Äbc", strSlice(try rt.evalString("(string-downcase \"ÄBC\")")));
    try expectError(error.ArityMismatch, rt.evalString("(string-upcase \"a\" \"b\")"));
    try expectError(error.TypeMismatch, rt.evalString("(string-downcase 1)"));
}

test "string-find" {
    var rt = try newRt();
    defer rt.deinit();
    try expectEqual(@as(i64, 6), (try rt.evalString("(string-find \"hello world\" \"world\")")).obj.toInt(i64));
    try expectEqual(@as(i64, 3), (try rt.evalString("(string-find \"hello\" \"lo\")")).obj.toInt(i64));
    try expect(Value.isNil(try rt.evalString("(string-find \"abc\" \"z\")")));
    try expectEqual(@as(i64, 0), (try rt.evalString("(string-find \"abc\" \"\")")).obj.toInt(i64));
    try expectEqual(@as(i64, 0), (try rt.evalString("(string-find \"abc\" \"abc\")")).obj.toInt(i64));
    try expect(Value.isNil(try rt.evalString("(string-find \"abc\" \"abcd\")")));
    try expectError(error.TypeMismatch, rt.evalString("(string-find \"abc\" 5)"));
}

test "string-replace" {
    var rt = try newRt();
    defer rt.deinit();
    try expectEqualStrings("bbb", strSlice(try rt.evalString("(string-replace \"aaa\" \"a\" \"b\")")));
    try expectEqualStrings("aXaX", strSlice(try rt.evalString("(string-replace \"abcabc\" \"bc\" \"X\")")));
    try expectEqualStrings("hello", strSlice(try rt.evalString("(string-replace \"hello\" \"x\" \"y\")")));
    // Non-overlapping: matches may not share bytes
    try expectEqualStrings("ba", strSlice(try rt.evalString("(string-replace \"aaa\" \"aa\" \"b\")")));
    try expectError(error.Unsupported, rt.evalString("(string-replace \"abc\" \"\" \"x\")"));
    try expectError(error.TypeMismatch, rt.evalString("(string-replace \"a\" 1 \"b\")"));
}

test "string-split" {
    var rt = try newRt();
    defer rt.deinit();
    try expectEqualStrings("(\"a\" \"b\" \"c\")", try fstr(rt, try rt.evalString("(string-split \"a,b,c\" \",\")")));
    try expectEqualStrings("(\"a\" \"\" \"b\")", try fstr(rt, try rt.evalString("(string-split \"a,,b\" \",\")")));
    try expectEqualStrings("(\"abc\")", try fstr(rt, try rt.evalString("(string-split \"abc\" \",\")")));
    try expectEqualStrings("(\"\")", try fstr(rt, try rt.evalString("(string-split \"\" \",\")")));
    try expectError(error.Unsupported, rt.evalString("(string-split \"abc\" \"\")"));
}

test "string-join" {
    var rt = try newRt();
    defer rt.deinit();
    try expectEqualStrings("a,b,c", strSlice(try rt.evalString("(string-join (list \"a\" \"b\" \"c\") \",\")")));
    try expectEqualStrings("ab", strSlice(try rt.evalString("(string-join (list \"a\" \"b\") \"\")")));
    try expectEqualStrings("", strSlice(try rt.evalString("(string-join (list) \",\")")));
    try expectError(error.TypeMismatch, rt.evalString("(string-join (list \"a\" 1) \",\")"));
    try expectError(error.Unsupported, rt.evalString("(string-join (cons \"a\" \"b\") \",\")"));
}

test "string-trim" {
    var rt = try newRt();
    defer rt.deinit();
    try expectEqualStrings("hi", strSlice(try rt.evalString("(string-trim \"  hi  \")")));
    try expectEqualStrings("", strSlice(try rt.evalString("(string-trim \"\\t\\n\")")));
    try expectEqualStrings("hi", strSlice(try rt.evalString("(string-trim-left \"  hi\")")));
    try expectEqualStrings("hi", strSlice(try rt.evalString("(string-trim-right \"hi  \")")));
    try expectEqualStrings("h i", strSlice(try rt.evalString("(string-trim \"h i\")")));
    try expectEqualStrings("x", strSlice(try rt.evalString("(string-trim \"x\")")));
    try expectError(error.TypeMismatch, rt.evalString("(string-trim 5)"));
}

test "string-includes? / starts-with? / ends-with?" {
    var rt = try newRt();
    defer rt.deinit();
    try expect((try rt.evalString("(string-includes? \"hello\" \"ell\")")).obj.toBool());
    try expect(!(try rt.evalString("(string-includes? \"hello\" \"x\")")).obj.toBool());
    try expect((try rt.evalString("(string-includes? \"hello\" \"\")")).obj.toBool());
    try expect((try rt.evalString("(string-starts-with? \"hello\" \"he\")")).obj.toBool());
    try expect(!(try rt.evalString("(string-starts-with? \"hello\" \"lo\")")).obj.toBool());
    try expect((try rt.evalString("(string-starts-with? \"hello\" \"\")")).obj.toBool());
    try expect((try rt.evalString("(string-ends-with? \"hello\" \"lo\")")).obj.toBool());
    try expect(!(try rt.evalString("(string-ends-with? \"hello\" \"he\")")).obj.toBool());
    try expect((try rt.evalString("(string-ends-with? \"hello\" \"\")")).obj.toBool());
    try expectError(error.TypeMismatch, rt.evalString("(string-includes? \"hello\" 1)"));
}

test "string-reverse" {
    var rt = try newRt();
    defer rt.deinit();
    try expectEqualStrings("cba", strSlice(try rt.evalString("(string-reverse \"abc\")")));
    try expectEqualStrings("", strSlice(try rt.evalString("(string-reverse \"\")")));
    try expectEqualStrings("a", strSlice(try rt.evalString("(string-reverse \"a\")")));
    try expectEqualStrings("b\na", strSlice(try rt.evalString("(string-reverse \"a\\nb\")")));
    // Codepoint-aware: é (C3 A9) reverses as a unit, preserving valid UTF-8.
    try expectEqualStrings("\u{e9}", strSlice(try rt.evalString("(string-reverse \"\\u{e9}\")")));
    try expectEqualStrings("oll\u{e9}h", strSlice(try rt.evalString("(string-reverse \"h\u{e9}llo\")")));
    try expectEqualStrings(
        "h\u{e9}llo",
        strSlice(try rt.evalString(
            "(string-reverse (string-reverse \"h\u{e9}llo\"))",
        )),
    );
    try expectError(error.TypeMismatch, rt.evalString("(string-reverse 1)"));
}

test "substring" {
    var rt = try newRt();
    defer rt.deinit();
    try expectEqualStrings("el", strSlice(try rt.evalString("(substring \"hello\" 1 3)")));
    try expectEqualStrings("hello", strSlice(try rt.evalString("(substring \"hello\" 0 5)")));
    try expectEqualStrings("", strSlice(try rt.evalString("(substring \"hello\" 3 3)")));
    try expectEqualStrings("llo", strSlice(try rt.evalString("(substring \"hello\" 2 5)")));
    try expectEqualStrings("", strSlice(try rt.evalString("(substring \"hello\" 0 0)")));
    // Char-aware: indices are codepoints, not bytes. "héllo" = h,é,l,l,o.
    try expectEqualStrings("\u{e9}l", strSlice(try rt.evalString("(substring \"h\u{e9}llo\" 1 3)")));
    try expectEqualStrings("h\u{e9}ll", strSlice(try rt.evalString("(substring \"h\u{e9}llo\" 0 4)")));
    try expectEqualStrings("llo", strSlice(try rt.evalString("(substring \"h\u{e9}llo\" 2 5)")));
    try expectEqualStrings("", strSlice(try rt.evalString("(substring \"h\u{e9}llo\" 5 5)")));
    try expectError(error.Unsupported, rt.evalString("(substring \"hello\" 2 6)"));
    try expectError(error.Unsupported, rt.evalString("(substring \"hello\" 3 1)"));
    try expectError(error.Unsupported, rt.evalString("(substring \"hello\" -1 2)"));
    try expectError(error.Unsupported, rt.evalString("(substring \"h\u{e9}llo\" 2 7)"));
    try expectError(error.TypeMismatch, rt.evalString("(substring \"hello\" 1.5 3)"));
}

test "string->list / list->string" {
    var rt = try newRt();
    defer rt.deinit();
    try expectEqualStrings("(97 98 99)", try fstr(rt, try rt.evalString("(string->list \"abc\")")));
    try expectEqualStrings("nil", try fstr(rt, try rt.evalString("(string->list \"\")")));
    try expectEqualStrings("(104 233)", try fstr(rt, try rt.evalString("(string->list \"h\u{e9}\")")));
    try expectEqualStrings("abc", strSlice(try rt.evalString("(list->string (list 97 98 99))")));
    try expectEqualStrings("", strSlice(try rt.evalString("(list->string (list))")));
    try expectEqualStrings("hi", strSlice(try rt.evalString("(list->string (list 104 105))")));
    // Integer widths accepted; codepoint encode of é.
    try expectEqualStrings("h\u{e9}", strSlice(try rt.evalString("(list->string (list 104 233))")));
    try expectError(error.Unsupported, rt.evalString("(list->string (list 97 0 98))"));
    try expectError(error.Unsupported, rt.evalString("(list->string (list 0))"));
    try expectError(error.Unsupported, rt.evalString("(list->string (list -1))"));
    try expectError(error.Unsupported, rt.evalString("(list->string (list 1114112))"));
    try expectError(error.Unsupported, rt.evalString("(list->string (list 55296))"));
    try expectError(error.TypeMismatch, rt.evalString("(list->string (list \"a\"))"));
    try expectError(error.Unsupported, rt.evalString("(list->string (cons 97 98))"));
    try expectError(error.TypeMismatch, rt.evalString("(list->string 5)"));
}

test "format" {
    var stdout_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout_writer.deinit();

    var rt = try newRt();
    defer rt.deinit();
    rt.stdout = &stdout_writer.writer;

    try expectEqualStrings("hi", strSlice(try rt.evalString("(format \"~a\" \"hi\")")));
    try expectEqualStrings("\"hi\"", strSlice(try rt.evalString("(format \"~s\" \"hi\")")));
    try expectEqualStrings("\"x\"", strSlice(try rt.evalString("(format \"~v\" \"x\")")));
    try expectEqualStrings("1 x", strSlice(try rt.evalString("(format \"~a ~a\" 1 \"x\")")));
    try expectEqualStrings("'sym", strSlice(try rt.evalString("(format \"~a\" 'sym)")));
    try expectEqualStrings("a\nb", strSlice(try rt.evalString("(format \"~a~n~a\" \"a\" \"b\")")));
    try expectEqualStrings("\n", strSlice(try rt.evalString("(format \"~%\")")));
    try expectEqualStrings("~a", strSlice(try rt.evalString("(format \"~~a\")")));
    try expectEqualStrings("42", strSlice(try rt.evalString("(format \"~a\" 42)")));
    try expectEqualStrings("42.0", strSlice(try rt.evalString("(format \"~a\" 42.0)")));
    try expectEqualStrings("#t", strSlice(try rt.evalString("(format \"~a\" #t)")));
    try expectEqualStrings("(1 2)", strSlice(try rt.evalString("(format \"~a\" (list 1 2))")));
    // printf renders, writes to the assigned writer, and returns null.
    const p = try rt.evalString("(printf \"hello ~a~n\" \"world\")");
    try stdout_writer.writer.flush();
    try expectEqualStrings("hello world\n", stdout_writer.written());
    try expect(Value.isNil(p));
    try expectError(error.ArityMismatch, rt.evalString("(format \"~a\")"));
    try expectError(error.Unsupported, rt.evalString("(format \"~q\" 1)"));
    try expectError(error.Unsupported, rt.evalString("(format \"abc~\")"));
    try expectError(error.TypeMismatch, rt.evalString("(format 42)"));
}

test "string-byte-ref" {
    var rt = try newRt();
    defer rt.deinit();
    const b0 = try rt.evalString("(string-byte-ref \"abc\" 0)");
    try expectEqual(skript.builtins.type_u8, b0.typ);
    try expectEqual(@as(u8, 97), b0.obj.toInt(u8));
    try expectEqual(@as(u8, 99), (try rt.evalString("(string-byte-ref \"abc\" 2)")).obj.toInt(u8));
    try expect((try rt.evalString("(@u8.eq (string-byte-ref \"abc\" 1) 98)")).obj.toBool());
    try expectError(error.Unsupported, rt.evalString("(string-byte-ref \"\" 0)"));
    try expectError(error.Unsupported, rt.evalString("(string-byte-ref \"abc\" 3)"));
    try expectError(error.Unsupported, rt.evalString("(string-byte-ref \"abc\" -1)"));
    try expectError(error.TypeMismatch, rt.evalString("(string-byte-ref \"abc\" 1.5)"));
}

test "number->string" {
    var rt = try newRt();
    defer rt.deinit();
    try expectEqualStrings("42", strSlice(try rt.evalString("(number->string 42)")));
    try expectEqualStrings("-7", strSlice(try rt.evalString("(number->string -7)")));
    try expectEqualStrings("0", strSlice(try rt.evalString("(number->string 0)")));
    try expectEqualStrings("255", strSlice(try rt.evalString("(number->string 255)")));
    try expectEqualStrings("ff", strSlice(try rt.evalString("(number->string 255 16)")));
    try expectEqualStrings("-ff", strSlice(try rt.evalString("(number->string -255 16)")));
    try expectEqualStrings("1000", strSlice(try rt.evalString("(number->string 8 2)")));
    try expectEqualStrings("100", strSlice(try rt.evalString("(number->string 64 8)")));
    try expectEqualStrings("3.14", strSlice(try rt.evalString("(number->string 3.14)")));
    try expectEqualStrings("42.0", strSlice(try rt.evalString("(number->string 42.0)")));
    try expectEqualStrings("1.0+2.0i", strSlice(try rt.evalString("(number->string 1+2i)")));
    try expectEqualStrings(
        "-9223372036854775808",
        strSlice(try rt.evalString(
            "(number->string -9223372036854775808)",
        )),
    );
    try expectError(error.Unsupported, rt.evalString("(number->string 10.5 2)"));
    try expectError(error.Unsupported, rt.evalString("(number->string 42 3)"));
    try expectError(error.TypeMismatch, rt.evalString("(number->string \"x\")"));
    try expectError(error.ArityMismatch, rt.evalString("(number->string)"));

    // u64 renders as its unsigned value (reader can't produce u64 > i64 max)
    try expectEqualStrings(
        "18446744073709551615",
        strSlice(try @"number->string"(
            rt.context(),
            .nil,
            .nil,
            &.{.u64(std.math.maxInt(u64))},
        )),
    );
    // f32 path
    try expectEqualStrings("3.14", strSlice(try @"number->string"(rt.context(), .nil, .nil, &.{.f32(3.14)})));
    try expectEqualStrings("2.5", strSlice(try @"number->string"(rt.context(), .nil, .nil, &.{.f32(2.5)})));
    // c16 / c32 paths (c64 exercised via the 1+2i literal above)
    try expectEqualStrings(
        "1.0+2.0i",
        strSlice(try @"number->string"(
            rt.context(),
            .nil,
            .nil,
            &.{
                try intrin.complex.c32Cart(
                    rt.context(),
                    .nil,
                    .nil,
                    &.{
                        .f32(1.0),
                        .f32(2.0),
                    },
                ),
            },
        )),
    );
    try expectEqualStrings(
        "1.0-2.0i",
        strSlice(try @"number->string"(
            rt.context(),
            .nil,
            .nil,
            &.{
                try intrin.complex.c16Cart(
                    rt.context(),
                    .nil,
                    .nil,
                    &.{
                        .f16(1.0),
                        .f16(-2.0),
                    },
                ),
            },
        )),
    );
}

test "string->number" {
    var rt = try newRt();
    defer rt.deinit();
    const v42 = try rt.evalString("(string->number \"42\")");
    try expectEqual(skript.builtins.type_i64, v42.typ);
    try expectEqual(@as(i64, 42), v42.obj.toInt(i64));
    try expectEqual(@as(i64, -17), (try rt.evalString("(string->number \"-17\")")).obj.toInt(i64));
    try expectEqual(@as(i64, 17), (try rt.evalString("(string->number \"+17\")")).obj.toInt(i64));
    try expectEqual(@as(i64, 255), (try rt.evalString("(string->number \"ff\" 16)")).obj.toInt(i64));
    try expectEqual(@as(i64, 5), (try rt.evalString("(string->number \"101\" 2)")).obj.toInt(i64));
    try expectEqual(@as(i64, 63), (try rt.evalString("(string->number \"77\" 8)")).obj.toInt(i64));
    const vf = try rt.evalString("(string->number \"3.14\")");
    try expectEqual(skript.builtins.type_f64, vf.typ);
    try expectEqual(@as(f64, 3.14), vf.obj.tof64());
    try expectEqual(@as(f64, 1000.0), (try rt.evalString("(string->number \"1e3\")")).obj.tof64());
    try expectEqual(@as(i64, 42), (try rt.evalString("(string->number \"  42  \")")).obj.toInt(i64));
    try expect(Value.isNil(try rt.evalString("(string->number \"abc\")")));
    try expect(Value.isNil(try rt.evalString("(string->number \"\")")));
    try expect(Value.isNil(try rt.evalString("(string->number \"   \")")));
    try expect(Value.isNil(try rt.evalString("(string->number \"ff\")")));
    try expect(Value.isNil(try rt.evalString("(string->number \"3.14\" 16)")));
    try expect(Value.isNil(try rt.evalString("(string->number \"0x10\")")));
    try expect(Value.isNil(try rt.evalString("(string->number \"99999999999999999999\")")));
    try expect(Value.isNil(try rt.evalString("(string->number \"18446744073709551615\")")));
    try expectError(error.Unsupported, rt.evalString("(string->number \"42\" 3)"));
    try expectError(error.TypeMismatch, rt.evalString("(string->number 42)"));
}

test "string->symbol / symbol->string" {
    var rt = try newRt();
    defer rt.deinit();
    const s1 = try rt.evalString("(string->symbol \"foo\")");
    try expectEqual(skript.builtins.type_symbol, s1.typ);
    try expectEqualStrings("foo", s1.obj.toPtr(Sym).*);
    // makeSymbol trims " \t\n\r"
    const s2 = try rt.evalString("(string->symbol \"  foo  \")");
    try expectEqualStrings("foo", s2.obj.toPtr(Sym).*);
    try expectEqualStrings("foo", strSlice(try rt.evalString("(symbol->string 'foo)")));
    try expectEqualStrings("bar", strSlice(try rt.evalString("(symbol->string (string->symbol \"bar\"))")));
    // Interning makes string->symbol injective: equality is object identity
    try expect((try rt.evalString("(= (string->symbol \"a\") (string->symbol \"a\"))")).obj.toBool());
    try expectError(error.TypeMismatch, rt.evalString("(symbol->string \"x\")"));
    try expectError(error.TypeMismatch, rt.evalString("(string->symbol 42)"));
}
