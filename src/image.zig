//! Kitty graphics image protocol: transmit, place, and delete images in
//! the terminal's image cache via APC sequences (`\x1b_G...\x1b\\`).
//!
//! Wire format (kitty graphics protocol):
//!   transmit: `\x1b_Ga=t,q=1,f=<fmt>,s=<w>,v=<h>[,i=<id>],m=<m>;<base64>\x1b\\`
//!     — `a=t` transmits ONLY: nothing is displayed until `place`
//!       renders it. `q=1` suppresses the OK response. Payload chunked
//!       across frames: the first frame carries the full parameter set
//!       with `m=1` while more chunks follow (`m=0` final); continuation
//!       frames carry only `m=1;`/`m=0;` before the payload.
//!   place:    CUP first: `\x1b[<row>;<col>H` then
//!             `\x1b_Ga=p,q=1,i=<id>[,p=<pid>][,c=<cells>,r=<cells>][,z=<z>]\x1b\\`
//!     — position is the MOVED CURSOR (`c`/`r` are the SPAN in cells);
//!       `p=` re-places (moves) an existing placement; no `w=`/`h=` —
//!       source cropping is not supported.
//!   delete:   `\x1b_Ga=d,q=1\x1b\\` (all) | `\x1b_Ga=d,q=1,i=<id>\x1b\\`
//!
//! Every writer is `w: anytype` and must be `std.Io.Writer`-compatible.
//! Base64 chunks are encoded into a fixed stack buffer — no allocation in
//! the hot path. No zg import — pure ANSI bytes.

const std = @import("std");

/// Kitty graphics protocol surface (`notui.image.kitty`).
pub const kitty = struct {
    /// APC introducer (`ESC _`).
    const apc = "\x1b_";
    /// ST terminator (`ESC \`).
    const st = "\x1b\\";
    /// Base64 chunk size; raw payload chunks are `(size / 4) * 3` bytes
    /// (zigzag `sendKittyGraphicsPayload` uses the same 4096-byte buffer).
    const chunk_b64 = 4096;

    /// Image payload formats (`f=` parameter). Raw pixel data is 24-bit
    /// RGB (`f=24`) or 32-bit RGBA (`f=32`); PNG bytes use `f=100`.
    pub const Format = enum { rgb, rgba, png };

    /// Display size in cells (`c`/`r` span).
    pub const CellSize = struct {
        width: u32,
        height: u32,
    };

    /// Options for `transmit`.
    pub const TransmitOptions = struct {
        /// Pixel layout of `data` (irrelevant to the terminal for `.png`).
        format: Format,
        /// Source width in pixels.
        width: u32,
        /// Source height in pixels.
        height: u32,
        /// Cache id for later `place`/`delete`; null lets the terminal
        /// assign one (an unnamed image cannot be re-placed).
        id: ?u32 = null,
    };

    /// Options for `place`.
    pub const PlaceOptions = struct {
        /// Cache id from a prior `transmit`.
        id: u32,
        /// 1-indexed column to place at.
        col: u32,
        /// 1-indexed row to place at.
        row: u32,
        /// Display size in CELLS (c/r span); null = native pixel size.
        size: ?CellSize = null,
        /// Placement id; re-placing the same (id, placement) moves the
        /// image without trails.
        placement: ?u32 = null,
        /// Stacking order; negative renders beneath text.
        z_index: ?i32 = null,
    };

    /// Transmit `data` to the Kitty graphics cache. `a=t` transmits
    /// ONLY — nothing is displayed; the image renders where `place`
    /// later puts it. `data` is raw pixels for `.rgb`/`.rgba`
    /// (`width*height*3` / `width*height*4` bytes) or PNG bytes for
    /// `.png`. The payload is base64-encoded and chunked into APC
    /// frames of at most 4096 base64 bytes (3072 raw bytes). `q=1`
    /// suppresses the OK response every frame would otherwise emit.
    ///
    /// Graceful: emits nothing when `width == 0`, `height == 0`, or
    /// `data.len == 0`.
    pub fn transmit(w: anytype, opts: TransmitOptions, data: []const u8) !void {
        if (opts.width == 0 or opts.height == 0 or data.len == 0) return;

        const encoder = std.base64.standard.Encoder;
        const raw_chunk_max = (chunk_b64 / 4) * 3;
        var b64_buf: [chunk_b64]u8 = undefined;

        var src_index: usize = 0;
        var first = true;
        while (true) {
            const take = @min(data.len - src_index, raw_chunk_max);
            const chunk = data[src_index .. src_index + take];
            const has_more = src_index + take < data.len;

            // encode returns the exact used slice; the 4096-byte buffer
            // always fits the encoded chunk (<= 4096 bytes).
            const encoded = encoder.encode(&b64_buf, chunk);

            try w.writeAll(apc ++ "G");
            if (first) {
                try w.print("a=t,q=1,f={d},s={d},v={d}", .{
                    formatCode(opts.format), opts.width, opts.height,
                });
                if (opts.id) |id| try w.print(",i={d}", .{id});
                try w.print(",m={d};", .{if (has_more) @as(u8, 1) else @as(u8, 0)});
                first = false;
            } else {
                try w.writeAll(if (has_more) "m=1;" else "m=0;");
            }
            try w.writeAll(encoded);
            try w.writeAll(st);

            if (!has_more) break;
            src_index += take;
        }
    }

    /// Place a previously transmitted image (`id`). Position is the
    /// MOVED CURSOR: CUP to the 1-indexed absolute `row`/`col` cell
    /// first, then this emits `a=p,q=1` there (`c`/`r` in the APC are
    /// the SPAN in cells). `p=` re-places an existing placement (moves
    /// it, no accumulation). `w`/`h` source cropping is not supported.
    /// `z_index` stacks (negative beneath text).
    pub fn place(w: anytype, opts: PlaceOptions) !void {
        try w.print("\x1b[{d};{d}H", .{ opts.row, opts.col });
        try w.print(apc ++ "Ga=p,q=1,i={d}", .{opts.id});
        if (opts.placement) |p| try w.print(",p={d}", .{p});
        if (opts.size) |size| try w.print(",c={d},r={d}", .{ size.width, size.height });
        if (opts.z_index) |z| try w.print(",z={d}", .{z});
        try w.writeAll(st);
    }

    /// Delete images from the Kitty cache. `null` deletes everything
    /// (`a=d,q=1`); an `id` deletes just that cached image
    /// (`a=d,q=1,i=<id>`).
    pub fn delete(w: anytype, id: ?u32) !void {
        try w.writeAll(apc ++ "G");
        if (id) |i| {
            try w.print("a=d,q=1,i={d}", .{i});
        } else {
            try w.writeAll("a=d,q=1");
        }
        try w.writeAll(st);
    }

    fn formatCode(f: Format) u8 {
        return switch (f) {
            .rgb => 24,
            .rgba => 32,
            .png => 100,
        };
    }
};

test {
    std.testing.refAllDecls(@This());
}

/// Fixed-buffer writer for golden tests. `init` must run in place —
/// the writer borrows `buf`, so the struct must not move afterwards.
/// Sized for the largest golden (two chunked APC frames, ~4.2 KB).
const TestWriter = struct {
    buf: [8192]u8 = undefined,
    w: std.Io.Writer = undefined,

    fn init(self: *TestWriter) void {
        self.w = .fixed(&self.buf);
    }
};

test "image: transmit single-chunk RGBA golden" {
    var t: TestWriter = .{};
    t.init();

    const data = [_]u8{
        0xff, 0x00, 0x00, 0xff, // red
        0x00, 0xff, 0x00, 0xff, // green
        0x00, 0x00, 0xff, 0xff, // blue
        0xff, 0xff, 0xff, 0xff, // white
    };
    try kitty.transmit(&t.w, .{ .format = .rgba, .width = 2, .height = 2 }, &data);

    // 16 raw bytes -> 24 base64 chars; single frame so m=0; no id -> no i=.
    try std.testing.expectEqualStrings(
        "\x1b_Ga=t,q=1,f=32,s=2,v=2,m=0;/wAA/wD/AP8AAP///////w==\x1b\\",
        t.w.buffered(),
    );
}

test "image: transmit with explicit cache id" {
    var t: TestWriter = .{};
    t.init();

    try kitty.transmit(&t.w, .{ .format = .png, .width = 1, .height = 1, .id = 42 }, "ABC");

    try std.testing.expectEqualStrings(
        "\x1b_Ga=t,q=1,f=100,s=1,v=1,i=42,m=0;QUJD\x1b\\",
        t.w.buffered(),
    );
}

test "image: transmit chunks large payload across m=1/m=0 frames" {
    var t: TestWriter = .{};
    t.init();

    // 3073 bytes = exactly one full 3072-byte (4096-base64) chunk plus a
    // 1-byte tail, forcing two frames: m=1 then m=0. 3072 'A' bytes encode
    // as "QUFB" x 1024; a trailing 'A' encodes as "QQ==".
    var data: [3073]u8 = undefined;
    @memset(&data, 'A');
    try kitty.transmit(&t.w, .{ .format = .rgba, .width = 32, .height = 32 }, &data);

    var expected: [8192]u8 = undefined;
    var ew = std.Io.Writer.fixed(&expected);
    try ew.writeAll("\x1b_Ga=t,q=1,f=32,s=32,v=32,m=1;");
    var i: usize = 0;
    while (i < 1024) : (i += 1) try ew.writeAll("QUFB");
    try ew.writeAll("\x1b\\\x1b_Gm=0;QQ==\x1b\\");

    try std.testing.expectEqualStrings(ew.buffered(), t.w.buffered());
}

test "image: transmit is a no-op for degenerate input" {
    var t: TestWriter = .{};
    t.init();
    try kitty.transmit(&t.w, .{ .format = .rgba, .width = 0, .height = 2 }, &[_]u8{1});
    try std.testing.expectEqualStrings("", t.w.buffered());

    var t2: TestWriter = .{};
    t2.init();
    try kitty.transmit(&t2.w, .{ .format = .rgba, .width = 2, .height = 0 }, &[_]u8{1});
    try std.testing.expectEqualStrings("", t2.w.buffered());

    var t3: TestWriter = .{};
    t3.init();
    try kitty.transmit(&t3.w, .{ .format = .rgba, .width = 2, .height = 2 }, "");
    try std.testing.expectEqualStrings("", t3.w.buffered());
}

test "image: place cached image" {
    var t: TestWriter = .{};
    t.init();
    try kitty.place(&t.w, .{ .id = 1, .col = 3, .row = 2 });
    try std.testing.expectEqualStrings("\x1b[2;3H\x1b_Ga=p,q=1,i=1\x1b\\", t.w.buffered());

    var t2: TestWriter = .{};
    t2.init();
    try kitty.place(&t2.w, .{ .id = 1, .col = 3, .row = 2, .z_index = -1 });
    try std.testing.expectEqualStrings(
        "\x1b[2;3H\x1b_Ga=p,q=1,i=1,z=-1\x1b\\",
        t2.w.buffered(),
    );

    var t3: TestWriter = .{};
    t3.init();
    try kitty.place(&t3.w, .{
        .id = 1,
        .col = 3,
        .row = 2,
        .size = .{ .width = 16, .height = 16 },
    });
    try std.testing.expectEqualStrings(
        "\x1b[2;3H\x1b_Ga=p,q=1,i=1,c=16,r=16\x1b\\",
        t3.w.buffered(),
    );

    var t4: TestWriter = .{};
    t4.init();
    try kitty.place(&t4.w, .{
        .id = 1,
        .col = 3,
        .row = 2,
        .size = .{ .width = 32, .height = 24 },
        .z_index = 5,
        .placement = 9,
    });
    try std.testing.expectEqualStrings(
        "\x1b[2;3H\x1b_Ga=p,q=1,i=1,p=9,c=32,r=24,z=5\x1b\\",
        t4.w.buffered(),
    );
}

test "image: delete all and delete by id" {
    var t: TestWriter = .{};
    t.init();
    try kitty.delete(&t.w, null);
    try std.testing.expectEqualStrings("\x1b_Ga=d,q=1\x1b\\", t.w.buffered());

    var t2: TestWriter = .{};
    t2.init();
    try kitty.delete(&t2.w, 7);
    try std.testing.expectEqualStrings("\x1b_Ga=d,q=1,i=7\x1b\\", t2.w.buffered());
}
