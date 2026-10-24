//! The Kitty graphics protocol: transmit, place and delete images through
//! APC-G sequences (`ESC _` … `ESC \`).
//!
//! Every writer takes `w: anytype` and works with any
//! `std.Io.Writer`-compatible sink. Base64 chunks are encoded into a fixed
//! stack buffer, so a transmit allocates nothing.
//!
//! An image is sent once with `transmit` and positioned afterwards with
//! `place`, which moves the cursor rather than carrying coordinates.
//!
//! Wire parameters used here:
//!
//! - transmit (`a=t`) sends without displaying; `q=1` suppresses the OK
//!   reply. A payload longer than one frame is chunked: the first frame
//!   carries the full parameter set with `m=1` while more follow, later
//!   frames carry only `m=1;` or `m=0;` before their chunk.
//! - place (`a=p`) is preceded by a CUP to the target cell. `c`/`r` are the
//!   span in CELLS, not a source size; `w`/`h` cropping is not supported.
//! - delete (`a=d`) with an id deletes one cached image, without one deletes
//!   all of them.

const std = @import("std");

/// Kitty graphics protocol surface (`notui.image.kitty`).
pub const kitty = struct {
    /// APC introducer, `ESC _`.
    const apc = "\x1b_";
    /// String terminator, `ESC \`.
    const st = "\x1b\\";
    /// Base64 characters per frame. It must be a multiple of 4 so that a
    /// frame of `(chunk_b64 / 4) * 3` raw bytes encodes to exactly
    /// `chunk_b64` characters and fills the scratch buffer.
    const chunk_b64 = 4096;

    /// The `f=` payload format: raw 24-bit RGB, raw 32-bit RGBA, or PNG.
    pub const Format = enum { rgb, rgba, png };

    /// A display size in cells.
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

    /// Send `data` to the terminal's image cache without displaying it;
    /// `place` renders it afterwards.
    ///
    /// `data` is raw pixels for `.rgb` and `.rgba` — `width * height * 3` and
    /// `width * height * 4` bytes respectively — and PNG bytes for `.png`,
    /// which this function does not measure. The payload is base64-encoded
    /// into frames of at most 4096 characters (3072 raw bytes each), and
    /// `q=1` suppresses the OK reply every frame would otherwise emit.
    ///
    /// `error.ImageSizeMismatch` when `data.len` disagrees with the geometry
    /// the raw formats declare, and `error.DegenerateImage` when `width` or
    /// `height` is 0: both leave the cache untouched, so a caller that
    /// transmits the wrong number of bytes never puts a corrupt image where a
    /// later `place` would find it.
    ///
    /// A writer error can leave a partial frame in the cache.
    pub fn transmit(w: anytype, opts: TransmitOptions, data: []const u8) !void {
        if (opts.width == 0 or opts.height == 0) return error.DegenerateImage;
        if (bytesPerPixel(opts.format)) |bpp| {
            // The pixel count cannot overflow u64 for two u32 extents, but
            // scaling it by the channel count can, and a wrapped size would
            // compare equal to a small payload.
            const pixels = @as(u64, opts.width) * @as(u64, opts.height);
            const declared = std.math.mul(u64, pixels, bpp) catch
                return error.ImageSizeMismatch;
            if (declared != data.len) return error.ImageSizeMismatch;
        } else if (data.len == 0) {
            return error.DegenerateImage;
        }

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

    /// Render an image already in the cache at the 1-indexed absolute cell
    /// `row`, `col`.
    ///
    /// Position is the moved cursor: this writes the CUP itself and leaves
    /// the cursor on the cell it placed at, so a caller that paints after
    /// this must move the cursor back. `size` is the span in CELLS (`c`/`r`),
    /// and omitting it asks for the image's native pixel size; `w`/`h` source
    /// cropping is not supported. Re-using the same (`id`, `placement`) moves
    /// the image instead of leaving a trail, and a negative `z_index` renders
    /// it beneath the text.
    ///
    /// `error.CellOutOfRange` without output when `row` or `col` is zero:
    /// this API requires explicit one-based cells. `Region.placeAt` derives them from
    /// a measured anchor.
    ///
    /// A writer error can leave the cursor moved with no placement emitted.
    pub fn place(w: anytype, opts: PlaceOptions) !void {
        if (opts.row == 0 or opts.col == 0) return error.CellOutOfRange;
        try w.print("\x1b[{d};{d}H", .{ opts.row, opts.col });
        try w.print(apc ++ "Ga=p,q=1,i={d}", .{opts.id});
        if (opts.placement) |p| try w.print(",p={d}", .{p});
        if (opts.size) |size| try w.print(",c={d},r={d}", .{ size.width, size.height });
        if (opts.z_index) |z| try w.print(",z={d}", .{z});
        try w.writeAll(st);
    }

    /// Remove images from the cache: `id` removes that one, and `null`
    /// removes all of them.
    ///
    /// A writer error can leave the delete half-written.
    pub fn delete(w: anytype, id: ?u32) !void {
        try w.writeAll(apc ++ "G");
        if (id) |i| {
            try w.print("a=d,q=1,i={d}", .{i});
        } else {
            try w.writeAll("a=d,q=1");
        }
        try w.writeAll(st);
    }

    /// Bytes per pixel for the raw formats, or null for `.png`, whose
    /// container carries its own geometry.
    fn bytesPerPixel(f: Format) ?u64 {
        return switch (f) {
            .rgb => 3,
            .rgba => 4,
            .png => null,
        };
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

test "image: transmit chunks a payload larger than one frame" {
    var t: TestWriter = .{};
    t.init();

    // 769 RGBA pixels are 3076 bytes: one full 3072-byte (4096-base64) chunk
    // plus a 4-byte tail, forcing two frames, m=1 then m=0. The
    // tail must retain all four bytes, including its base64 padding.
    var data: [769 * 4]u8 = undefined;
    @memset(&data, 'A');
    try kitty.transmit(&t.w, .{ .format = .rgba, .width = 769, .height = 1 }, &data);

    var expected: [8192]u8 = undefined;
    var ew = std.Io.Writer.fixed(&expected);
    try ew.writeAll("\x1b_Ga=t,q=1,f=32,s=769,v=1,m=1;");
    var i: usize = 0;
    while (i < 1024) : (i += 1) try ew.writeAll("QUFB");
    try ew.writeAll("\x1b\\\x1b_Gm=0;QUFBQQ==\x1b\\");

    try std.testing.expectEqualStrings(ew.buffered(), t.w.buffered());
}

test "image: transmit rejects geometry that does not match the payload" {
    // The terminal would cache a truncated or over-long image and a later
    // place would render it as-is, so a mismatch has to be reported rather
    // than transmitted.
    var t: TestWriter = .{};
    t.init();
    try std.testing.expectError(
        error.ImageSizeMismatch,
        kitty.transmit(&t.w, .{ .format = .rgba, .width = 2, .height = 2 }, &[_]u8{1}),
    );
    try std.testing.expectEqualStrings("", t.w.buffered());

    var t2: TestWriter = .{};
    t2.init();
    try std.testing.expectError(
        error.ImageSizeMismatch,
        kitty.transmit(&t2.w, .{ .format = .rgb, .width = 2, .height = 2 }, &@as([16]u8, @splat(1))),
    );
    try std.testing.expectEqualStrings("", t2.w.buffered());

    // A zero extent has no pixels to send, whatever the payload holds.
    var t3: TestWriter = .{};
    t3.init();
    try std.testing.expectError(
        error.DegenerateImage,
        kitty.transmit(&t3.w, .{ .format = .rgba, .width = 0, .height = 2 }, &[_]u8{1}),
    );
    try std.testing.expectError(
        error.ImageSizeMismatch,
        kitty.transmit(&t3.w, .{ .format = .rgba, .width = 2, .height = 2 }, ""),
    );
    try std.testing.expectError(
        error.DegenerateImage,
        kitty.transmit(&t3.w, .{ .format = .png, .width = 1, .height = 1 }, ""),
    );
    try std.testing.expectEqualStrings("", t3.w.buffered());
}

test "image: transmit does not measure a png payload" {
    // PNG carries its own geometry, so the declared size is advisory and any
    // non-empty payload goes through.
    var t: TestWriter = .{};
    t.init();
    try kitty.transmit(&t.w, .{ .format = .png, .width = 7, .height = 9 }, "PNGDATA");
    try std.testing.expect(std.mem.indexOf(u8, t.w.buffered(), "s=7,v=9") != null);
}

test "image: place rejects a zero cell" {
    var t: TestWriter = .{};
    t.init();
    try std.testing.expectError(
        error.CellOutOfRange,
        kitty.place(&t.w, .{ .id = 1, .col = 0, .row = 2 }),
    );
    try std.testing.expectError(
        error.CellOutOfRange,
        kitty.place(&t.w, .{ .id = 1, .col = 3, .row = 0 }),
    );
    try std.testing.expectEqualStrings("", t.w.buffered());
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
