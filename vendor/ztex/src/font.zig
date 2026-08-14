//! ztex.font — minimal OTF/TTF font parser + cached FontContext.
//!
//! Two layers:
//! - `FontFace`: a parsed font. Handles the sfnt container and the tables
//!   needed for horizontal metrics: `head` (unitsPerEm), `hhea`
//!   (ascender/descender/lineGap), `hmtx` (per-glyph advance widths),
//!   `maxp` (glyph count), `OS/2` (sTypo*/usWin* extents), and `cmap`
//!   (codepoint → glyph id, formats 4 and 12). Both OTF (`OTTO`/CFF) and
//!   TTF (0x00010000/glyf) containers parse through the same code. Metrics
//!   always; glyph outlines (`glyphOutline`) read `loca`/`glyf` (quadratic
//!   TrueType) or execute the Type 2 charstring + Subr INDEXes from the
//!   `CFF ` table (cubic, flattened to quadratics).
//! - `FontContext`: the "init once, render many" core. Owns the embedded
//!   Latin Modern fallback faces (LM Math + LM Roman regular/italic),
//!   caches faces loaded from disk by path, memoizes disk discovery in
//!   `findFont`, and serves per-(face, cp) metric lookups from a cache.
//!
//! All values returned in "em" units are font-relative (value ÷ unitsPerEm),
//! so callers multiply by the desired size in points. Every number asserted
//! in the tests below was measured from the real fonts (see
//! notes/font-context.md for the measurement method).

const std = @import("std");
const builtin = @import("builtin");

const lmmath = @import("fonts/lmmath.zig");
const lmroman_regular = @import("fonts/lmroman_regular.zig");
const lmroman_italic = @import("fonts/lmroman_italic.zig");

/// Per-glyph metrics at a given size, in points.
pub const GlyphMetrics = struct {
    /// Horizontal advance (width).
    width: f32,
    /// Nominal ascent (font hhea ascender) at this size.
    height: f32,
    /// Nominal descent (positive; -hhea descender) at this size.
    depth: f32,
    /// Nominal line gap (hhea lineGap) at this size.
    line_gap: f32,
};

/// Errors from parsing a font. All tables are bounds-checked.
pub const FontError = error{
    /// Not an sfnt container (bad scaler or truncated header).
    InvalidSfnt,
    /// A required table (head/hhea/hmtx/cmap/maxp) is missing.
    MissingTable,
    /// A table exists but its contents are malformed.
    InvalidTable,
    /// No usable cmap subtable (neither format 4 nor format 12).
    UnsupportedCmap,
    /// CFF is CID-keyed (ROS in the Top DICT); FDArray-based charstrings
    /// are not decoded.
    UnsupportedFont,
};

/// A quadratic Bézier segment in font units (em), Y-up (y grows up,
/// FreeType convention). TrueType glyphs are quadratic by construction;
/// a line is stored with p1 = midpoint(p0, p2).
pub const QuadCurve = struct {
    p0: [2]f32,
    p1: [2]f32,
    p2: [2]f32,
};

/// A glyph's outline: every contour reduced to quadratic segments.
/// Points are in font units (em), Y-up. Free with `deinit`.
pub const Outline = struct {
    gpa: std.mem.Allocator,
    curves: std.ArrayList(QuadCurve) = .empty,

    pub fn deinit(self: *Outline) void {
        self.curves.deinit(self.gpa);
        self.* = undefined;
    }
};

/// Bounds-checked big-endian reader over a table slice.
const Reader = struct {
    data: []const u8,

    fn readU8(self: Reader, off: usize) error{InvalidTable}!u8 {
        if (off + 1 > self.data.len) return error.InvalidTable;
        return self.data[off];
    }

    fn readU16(self: Reader, off: usize) error{InvalidTable}!u16 {
        if (off + 2 > self.data.len) return error.InvalidTable;
        return std.mem.readInt(u16, self.data[off..][0..2], .big);
    }

    fn readI16(self: Reader, off: usize) error{InvalidTable}!i16 {
        if (off + 2 > self.data.len) return error.InvalidTable;
        return std.mem.readInt(i16, self.data[off..][0..2], .big);
    }

    fn readI32(self: Reader, off: usize) error{InvalidTable}!i32 {
        if (off + 4 > self.data.len) return error.InvalidTable;
        return std.mem.readInt(i32, self.data[off..][0..4], .big);
    }

    fn readU32(self: Reader, off: usize) error{InvalidTable}!u32 {
        if (off + 4 > self.data.len) return error.InvalidTable;
        return std.mem.readInt(u32, self.data[off..][0..4], .big);
    }
};

/// Compile-time 4-byte sfnt tag (e.g. `tag("head")`).
fn tag(comptime s: []const u8) u32 {
    comptime std.debug.assert(s.len == 4);
    return (@as(u32, s[0]) << 24) | (@as(u32, s[1]) << 16) | (@as(u32, s[2]) << 8) | @as(u32, s[3]);
}

const TableLoc = struct {
    offset: usize,
    length: usize,
};

/// Locate a table record in the sfnt directory.
fn findTable(data: []const u8, want: u32) !TableLoc {
    if (data.len < 12) return error.InvalidSfnt;
    const num_tables = try (Reader{ .data = data }).readU16(4);
    if (12 + 16 * num_tables > data.len) return error.InvalidSfnt;
    var i: u32 = 0;
    while (i < num_tables) : (i += 1) {
        const rec = 12 + 16 * i;
        const have = std.mem.readInt(u32, data[rec..][0..4], .big);
        if (have != want) continue;
        const offset = try (Reader{ .data = data }).readU32(rec + 8);
        const length = try (Reader{ .data = data }).readU32(rec + 12);
        if (offset + length > data.len) return error.InvalidSfnt;
        return .{ .offset = offset, .length = length };
    }
    return error.MissingTable;
}

/// Priority score for a cmap subtable's platform/encoding pair, per the
/// OpenType recommendation (higher wins). We keep the best format-12 and the
/// best format-4 subtable independently; lookup prefers 12 (full repertoire)
/// and falls back to 4 (BMP).
fn cmapScore(platform: u16, encoding: u16) u8 {
    if (platform == 3 and encoding == 10) return 9;
    if (platform == 0 and encoding == 6) return 8;
    if (platform == 0 and encoding == 4) return 7;
    if (platform == 3 and encoding == 1) return 6;
    if (platform == 0 and encoding == 3) return 5;
    if (platform == 0 and encoding == 2) return 4;
    if (platform == 3 and encoding == 0) return 3;
    if (platform == 1 and encoding == 0) return 2;
    return 1;
}

/// Pick the best format-4 and format-12 subtables from a cmap table.
fn selectCmap(face: *FontFace, table: []const u8) FontError!void {
    const r: Reader = .{ .data = table };
    const num_subtables = try r.readU16(2);
    var best4: ?[]const u8 = null;
    var best4_score: u8 = 0;
    var best12: ?[]const u8 = null;
    var best12_score: u8 = 0;
    var i: u32 = 0;
    while (i < num_subtables) : (i += 1) {
        const rec = 4 + 8 * i;
        const platform = try r.readU16(rec);
        const encoding = try r.readU16(rec + 2);
        const offset: usize = try r.readU32(rec + 4);
        const format = try r.readU16(offset);
        const sub: []const u8 = switch (format) {
            4 => blk: {
                const len: usize = try r.readU16(offset + 2);
                if (offset + len > table.len) return error.InvalidTable;
                break :blk table[offset..][0..len];
            },
            12 => blk: {
                const len: usize = try r.readU32(offset + 4);
                if (offset + len > table.len) return error.InvalidTable;
                break :blk table[offset..][0..len];
            },
            else => continue, // formats 0/6/13/14 are not needed for metrics
        };
        const score = cmapScore(platform, encoding);
        if (format == 4 and score > best4_score) {
            best4 = sub;
            best4_score = score;
        } else if (format == 12 and score > best12_score) {
            best12 = sub;
            best12_score = score;
        }
    }
    if (best4 == null and best12 == null) return error.UnsupportedCmap;
    face.cmap4 = best4;
    face.cmap12 = best12;
}

/// Format 12 (segmented coverage) lookup: binary search over groups sorted
/// by startCharCode. Handles the full Unicode range.
fn cmap12Lookup(table: []const u8, cp: u21) ?u32 {
    const r: Reader = .{ .data = table };
    const num_groups = r.readU32(12) catch return null;
    var lo: u32 = 0;
    var hi: u32 = num_groups;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if ((r.readU32(16 + 12 * mid + 4) catch return null) < cp) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo >= num_groups) return null;
    const start = r.readU32(16 + 12 * lo) catch return null;
    if (cp < start) return null;
    const gid_start = r.readU32(16 + 12 * lo + 8) catch return null;
    return gid_start + (cp - start);
}

/// Format 4 (segment mapping to delta values) lookup: binary search over
/// endCode, then apply the segment delta or glyphIdArray indirection. BMP
/// only (callers gate `cp <= 0xFFFF`).
fn cmap4Lookup(table: []const u8, cp: u16) ?u32 {
    const r: Reader = .{ .data = table };
    const seg_count_x2: usize = r.readU16(6) catch return null;
    const seg_count = seg_count_x2 / 2;
    const end_base: usize = 14;
    const start_base = end_base + seg_count_x2 + 2;
    const delta_base = start_base + seg_count_x2;
    const ro_base = delta_base + seg_count_x2;
    var lo: usize = 0;
    var hi: usize = seg_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if ((r.readU16(end_base + 2 * mid) catch return null) < cp) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo >= seg_count) return null;
    const i = lo;
    const start = r.readU16(start_base + 2 * i) catch return null;
    if (cp < start) return null;
    const delta: u16 = @bitCast(r.readI16(delta_base + 2 * i) catch return null);
    const id_range_offset: usize = r.readU16(ro_base + 2 * i) catch return null;
    if (id_range_offset == 0) {
        // gid = (cp + delta) mod 65536
        return cp +% delta;
    }
    // gid sits in the glyphIdArray, addressed from this idRangeOffset entry.
    const gid16 = r.readU16(ro_base + 2 * i + id_range_offset + 2 * (cp - start)) catch return null;
    if (gid16 == 0) return null;
    return gid16 +% delta;
}

/// A parsed font. Owns a private copy of the file bytes (via `fromBytes`)
/// or is arena-managed by a `FontContext` (gpa == null, never deinit'd).
pub const FontFace = struct {
    /// Allocator that owns `data`; null when a FontContext's arena owns it.
    gpa: ?std.mem.Allocator,
    /// Owned copy of the whole font file (sfnt container).
    data: []u8,

    units_per_em: u16,
    num_glyphs: u16,

    // hhea
    hhea_ascender: i16,
    hhea_descender: i16,
    hhea_line_gap: i16,
    num_h_metrics: u16,

    // OS/2 (optional table; zero when absent)
    os2_typo_ascender: i16,
    os2_typo_descender: i16,
    os2_typo_line_gap: i16,
    os2_win_ascent: u16,
    os2_win_descent: u16,

    /// hmtx table slice (into `data`); first num_h_metrics entries are
    /// (advanceWidth u16, lsb i16) pairs, later glyphs share the last advance.
    hmtx: []const u8,

    /// Selected cmap subtables (into `data`), null when the font lacks one.
    cmap4: ?[]const u8,
    cmap12: ?[]const u8,

    /// loca table slice (into `data`); null for CFF/OTF fonts (no glyf).
    loca: ?[]const u8,
    /// glyf table slice (into `data`); null for CFF/OTF fonts.
    glyf: ?[]const u8,
    /// head.indexToLocFormat: 0 = short loca (u16 offsets × 2), 1 = long
    /// (u32 offsets).
    index_to_loc_format: i16,

    /// Parsed CFF structure (CharStrings/Subr INDEXes into `data`); null
    /// for TrueType fonts (no `CFF ` table).
    cff: ?CffData,
    /// True when the scaler was 'OTTO' (OpenType/CFF): outlines come from
    /// Type 2 charstrings, not glyf.
    is_cff: bool,
    /// True when the Top DICT declares ROS (CID-keyed). Charstrings then
    /// need FDArray/FDSelect; glyphOutline reports UnsupportedFont.
    cff_cid: bool,

    /// Parse `data` into a face, duplicating the bytes into `gpa`.
    /// The returned face owns its copy; free it with `deinit`.
    pub fn fromBytes(gpa: std.mem.Allocator, data: []const u8) !FontFace {
        const owned = try gpa.dupe(u8, data);
        errdefer gpa.free(owned);
        return parseOwned(owned, gpa);
    }

    /// Release the owned byte copy. No-op for arena-managed faces (gpa null).
    pub fn deinit(self: *FontFace) void {
        if (self.gpa) |gpa| gpa.free(self.data);
        self.* = undefined;
    }

    /// Font design size in font units per em (head.unitsPerEm).
    pub fn unitsPerEm(self: *const FontFace) u16 {
        return self.units_per_em;
    }

    /// Nominal ascent, em units (hhea.ascent ÷ upem).
    pub fn ascenderEm(self: *const FontFace) f32 {
        const upem: f32 = @floatFromInt(self.units_per_em);
        return @as(f32, @floatFromInt(self.hhea_ascender)) / upem;
    }

    /// Nominal descent, em units, positive (-hhea.descent ÷ upem).
    pub fn descenderEm(self: *const FontFace) f32 {
        const upem: f32 = @floatFromInt(self.units_per_em);
        return @as(f32, @floatFromInt(-self.hhea_descender)) / upem;
    }

    /// Nominal line gap, em units (hhea.lineGap ÷ upem).
    pub fn lineGapEm(self: *const FontFace) f32 {
        const upem: f32 = @floatFromInt(self.units_per_em);
        return @as(f32, @floatFromInt(self.hhea_line_gap)) / upem;
    }

    /// OS/2 sTypoAscender, em units.
    pub fn typoAscenderEm(self: *const FontFace) f32 {
        const upem: f32 = @floatFromInt(self.units_per_em);
        return @as(f32, @floatFromInt(self.os2_typo_ascender)) / upem;
    }

    /// OS/2 sTypoDescender, em units, positive.
    pub fn typoDescenderEm(self: *const FontFace) f32 {
        const upem: f32 = @floatFromInt(self.units_per_em);
        return @as(f32, @floatFromInt(-self.os2_typo_descender)) / upem;
    }

    /// OS/2 sTypoLineGap, em units.
    pub fn typoLineGapEm(self: *const FontFace) f32 {
        const upem: f32 = @floatFromInt(self.units_per_em);
        return @as(f32, @floatFromInt(self.os2_typo_line_gap)) / upem;
    }

    /// OS/2 usWinAscent (clipping extent), em units.
    pub fn winAscentEm(self: *const FontFace) f32 {
        const upem: f32 = @floatFromInt(self.units_per_em);
        return @as(f32, @floatFromInt(self.os2_win_ascent)) / upem;
    }

    /// OS/2 usWinDescent (clipping extent), em units.
    pub fn winDescentEm(self: *const FontFace) f32 {
        const upem: f32 = @floatFromInt(self.units_per_em);
        return @as(f32, @floatFromInt(self.os2_win_descent)) / upem;
    }

    /// Map a Unicode codepoint to a glyph id via the best cmap subtable
    /// (format 12 first, then format 4). Null when the font has no glyph.
    pub fn glyphIndex(self: *const FontFace, cp: u21) ?u32 {
        if (self.cmap12) |t| {
            if (cmap12Lookup(t, cp)) |gid| return gid;
        }
        if (self.cmap4) |t| {
            if (cp <= 0xFFFF) {
                if (cmap4Lookup(t, @intCast(cp))) |gid| return gid;
            }
        }
        return null;
    }

    /// True when the font's cmap maps `cp` to a glyph (glyphIndex != null).
    /// The cmap-validation primitive for the math-italic mapping: a mapped
    /// Mathematical-Alphanumeric-Symbols codepoint (U+1D4xx/U+1D6xx) is
    /// only emitted when the font actually carries the glyph.
    pub fn hasGlyph(self: *const FontFace, cp: u21) bool {
        return self.glyphIndex(cp) != null;
    }

    /// Horizontal advance for a glyph, em units (hmtx ÷ upem). Glyph ids
    /// past the explicit metric list share the last advance (hmtx
    /// convention); out-of-range ids clamp to the last glyph.
    pub fn advanceEm(self: *const FontFace, gid: u32) f32 {
        const n: u32 = self.num_h_metrics;
        const i: usize = @min(gid, n - 1);
        const adv = std.mem.readInt(u16, self.hmtx[4 * i ..][0..2], .big);
        // f64 intermediate: both values are exact there, and the division
        // result is then narrowed explicitly to the f32 metric.
        const adv_f: f64 = @floatFromInt(adv);
        const upem_f: f64 = @floatFromInt(self.units_per_em);
        return @floatCast(adv_f / upem_f);
    }

    /// Decode a glyph's quadratic outline. TrueType fonts read glyf/loca;
    /// OpenType/CFF fonts execute the glyph's Type 2 charstring against the
    /// Subr INDEXes and flatten the resulting cubics to quadratics. Empty
    /// charstrings (e.g. space) return an Outline with zero curves. Errors:
    /// MissingTable for fonts with neither glyf nor CFF, InvalidTable for
    /// out-of-range glyph ids or malformed charstrings, UnsupportedFont for
    /// CID-keyed CFF. Curves are in font units (em), Y-up.
    pub fn glyphOutline(self: *FontFace, gpa: std.mem.Allocator, gid: u32) !Outline {
        var out: Outline = .{ .gpa = gpa };
        errdefer out.deinit();
        if (self.is_cff) {
            if (self.cff_cid) return error.UnsupportedFont;
            const cff = self.cff orelse return error.MissingTable;
            if (gid >= self.num_glyphs) return error.InvalidTable;
            const char_string = try cffItem(cff.char_strings, self.data, gid);
            var interp = CffInterp.init(gpa, self.data, cff, &out.curves);
            if (!try interp.run(char_string, false)) return error.InvalidTable;
            return out;
        }
        try self.loadGlyph(gpa, gid, 0, &out.curves);
        return out;
    }

    /// Append the glyf data of `gid` (simple or composite) to `curves`.
    /// `depth` bounds composite recursion so malformed cycles error out
    /// instead of running away.
    fn loadGlyph(
        self: *const FontFace,
        gpa: std.mem.Allocator,
        gid: u32,
        depth: u32,
        curves: *std.ArrayList(QuadCurve),
    ) OutlineError!void {
        if (depth > max_composite_depth) return error.InvalidTable;
        const glyf = self.glyf orelse return error.MissingTable;
        const loca = self.loca orelse return error.MissingTable;
        if (gid >= self.num_glyphs) return error.InvalidTable;
        const start = self.locaOffset(loca, gid) orelse return error.InvalidTable;
        const end = self.locaOffset(loca, gid + 1) orelse return error.InvalidTable;
        if (start > end or end > glyf.len) return error.InvalidTable;
        if (end == start) return; // empty glyph (space etc.): no curves
        const data = glyf[start..end];
        const num_contours = try (Reader{ .data = data }).readI16(0);
        if (num_contours >= 0) return loadSimple(gpa, num_contours, data, curves);
        if (num_contours == -1) return loadComposite(self, gpa, data, depth, curves);
        // numberOfContours < -1 (e.g. -2): degenerate, no curves.
    }

    /// Byte offset of glyph `gid` within the glyf table, from its loca
    /// entry. Short loca stores u16 values × 2; long stores u32 directly.
    /// Null for a malformed format or an out-of-range entry.
    fn locaOffset(self: *const FontFace, loca: []const u8, gid: u32) ?usize {
        const r: Reader = .{ .data = loca };
        return switch (self.index_to_loc_format) {
            0 => blk: {
                const v = r.readU16(2 * gid) catch return null;
                break :blk @as(usize, v) * 2;
            },
            1 => blk: {
                const v = r.readU32(4 * gid) catch return null;
                break :blk v;
            },
            else => null,
        };
    }
};

/// Parse an owned byte blob into a face. `gpa` is stored for `deinit`; pass
/// null when a FontContext arena manages the memory (deinit becomes a no-op).
fn parseOwned(data: []u8, gpa: ?std.mem.Allocator) FontError!FontFace {
    if (data.len < 12) return error.InvalidSfnt;
    const scaler = std.mem.readInt(u32, data[0..4], .big);
    // 0x00010000 = TrueType (glyf), 'OTTO' = OpenType/CFF. Metrics come from
    // the same sfnt tables either way; only the TTF scaler implies glyf
    // outline data (CFF glyphs live in charstrings, out of scope).
    if (scaler != 0x00010000 and scaler != 0x4F54544F) return error.InvalidSfnt;

    const head = try findTable(data, tag("head"));
    const hhea = try findTable(data, tag("hhea"));
    const hmtx = try findTable(data, tag("hmtx"));
    const cmap = try findTable(data, tag("cmap"));
    const maxp = try findTable(data, tag("maxp"));
    const os2 = findTable(data, tag("OS/2")) catch null;
    // Outline tables: either glyf/loca (TrueType) or `CFF ` (OpenType/CFF).
    // Metrics parse identically either way; glyphOutline dispatches on the
    // scaler.
    const loca = findTable(data, tag("loca")) catch null;
    const glyf = findTable(data, tag("glyf")) catch null;
    const cff = findTable(data, tag("CFF ")) catch null;

    const hr: Reader = .{ .data = data[head.offset..][0..head.length] };
    const units_per_em = try hr.readU16(18);
    if (units_per_em == 0) return error.InvalidTable;

    const hhr: Reader = .{ .data = data[hhea.offset..][0..hhea.length] };
    const num_h_metrics = try hhr.readU16(34);
    if (num_h_metrics == 0) return error.InvalidTable;
    if (hmtx.length < 4 * num_h_metrics) return error.InvalidTable;

    const mr: Reader = .{ .data = data[maxp.offset..][0..maxp.length] };
    const num_glyphs = try mr.readU16(4);

    var face: FontFace = .{
        .gpa = gpa,
        .data = data,
        .units_per_em = units_per_em,
        .num_glyphs = num_glyphs,
        .hhea_ascender = try hhr.readI16(4),
        .hhea_descender = try hhr.readI16(6),
        .hhea_line_gap = try hhr.readI16(8),
        .num_h_metrics = num_h_metrics,
        .os2_typo_ascender = 0,
        .os2_typo_descender = 0,
        .os2_typo_line_gap = 0,
        .os2_win_ascent = 0,
        .os2_win_descent = 0,
        .hmtx = data[hmtx.offset..][0..hmtx.length],
        .cmap4 = null,
        .cmap12 = null,
        .loca = if (loca) |l| data[l.offset..][0..l.length] else null,
        .glyf = if (glyf) |g| data[g.offset..][0..g.length] else null,
        .index_to_loc_format = hr.readI16(50) catch 0,
        .cff = null,
        .is_cff = scaler == 0x4F54544F,
        .cff_cid = false,
    };
    if (cff) |c| {
        var cff_data: CffData = .{
            .char_strings = undefined,
            .gsubrs = undefined,
            .lsubrs = null,
            .gsubr_bias = 107,
            .lsubr_bias = 107,
        };
        face.cff_cid = try parseCffData(data, c, &cff_data);
        face.cff = cff_data;
    }
    if (os2) |o| {
        const or_: Reader = .{ .data = data[o.offset..][0..o.length] };
        // Fields exist from OS/2 version 0; read with defaults on any
        // malformed/truncated table.
        face.os2_typo_ascender = or_.readI16(68) catch 0;
        face.os2_typo_descender = or_.readI16(70) catch 0;
        face.os2_typo_line_gap = or_.readI16(72) catch 0;
        face.os2_win_ascent = or_.readU16(74) catch 0;
        face.os2_win_descent = or_.readU16(76) catch 0;
    }
    try selectCmap(&face, data[cmap.offset..][0..cmap.length]);
    return face;
}

/// Composite recursion cap; malformed component cycles error out instead of
/// recursing forever.
const max_composite_depth = 4;

/// Outline-decoding errors: OOM, a malformed/truncated table, or a font
/// without glyf data (CFF). Explicit so loadGlyph ↔ loadComposite (mutual
/// recursion) do not form an inferred-error-set cycle.
const OutlineError = error{ OutOfMemory, InvalidTable, MissingTable };

/// A decoded point of a simple glyph (font units, Y-up).
const GlyphPoint = struct {
    x: f32,
    y: f32,
    on_curve: bool,
};

/// A signed F2Dot14 fixed-point value (OpenType composite scales).
fn f2dot14(v: i16) f32 {
    return @as(f32, @floatFromInt(v)) / 16384.0;
}

fn xy(p: GlyphPoint) [2]f32 {
    return .{ p.x, p.y };
}

fn midPoint(a: [2]f32, b: [2]f32) [2]f32 {
    return .{ 0.5 * (a[0] + b[0]), 0.5 * (a[1] + b[1]) };
}

/// Apply a composite component transform: translate (dx, dy) after the
/// optional scale/shear (identity factors when no scale flags were set).
/// The offset is unscaled, per the spec.
fn transformPoint(p: [2]f32, dx: i32, dy: i32, sx: f32, sy: f32, s01: f32, s10: f32) [2]f32 {
    const dxf: f32 = @floatFromInt(dx);
    const dyf: f32 = @floatFromInt(dy);
    return .{ sx * p[0] + s01 * p[1] + dxf, s10 * p[0] + sy * p[1] + dyf };
}

/// Decode a simple glyph (numberOfContours >= 0): endPtsOfContours,
/// instructions (skipped), flags with optional repeats, x/y deltas; then
/// decompose each contour into quadratic segments appended to `curves`.
/// Every read is bounds-checked; trailing padding is ignored.
fn loadSimple(
    gpa: std.mem.Allocator,
    num_contours: i16,
    data: []const u8,
    curves: *std.ArrayList(QuadCurve),
) error{ OutOfMemory, InvalidTable }!void {
    const r: Reader = .{ .data = data };
    const n_contours: usize = @intCast(num_contours);
    var pos: usize = 10; // numberOfContours + 8-byte bounding box

    // endPtsOfContours: strictly increasing, last entry = point count - 1.
    const ends = try gpa.alloc(u32, n_contours);
    defer gpa.free(ends);
    var prev_end: i32 = -1;
    var i: usize = 0;
    while (i < n_contours) : (i += 1) {
        const e = try r.readU16(pos);
        pos += 2;
        if (@as(i32, e) <= prev_end) return error.InvalidTable;
        ends[i] = e;
        prev_end = @as(i32, e);
    }
    const n_points: usize = @as(usize, @intCast(prev_end)) + 1;

    const inst_len = try r.readU16(pos);
    pos += 2;
    if (pos + inst_len > data.len) return error.InvalidTable;
    pos += inst_len;

    // Flags; a repeat bit (0x08) extends the current flag to `n` more points.
    const flags = try gpa.alloc(u8, n_points);
    defer gpa.free(flags);
    var n: usize = 0;
    while (n < n_points) {
        const f = try r.readU8(pos);
        pos += 1;
        flags[n] = f;
        n += 1;
        if (f & 0x08 != 0) {
            const rep = try r.readU8(pos);
            pos += 1;
            if (rep > n_points - n) return error.InvalidTable;
            var j: usize = 0;
            while (j < rep) : (j += 1) {
                flags[n] = f;
                n += 1;
            }
        }
    }

    // x deltas, then y deltas (accumulated; saturated adds keep absurd
    // deltas from overflowing the i32 accumulator).
    const points = try gpa.alloc(GlyphPoint, n_points);
    defer gpa.free(points);
    var x: i32 = 0;
    n = 0;
    while (n < n_points) : (n += 1) {
        const f = flags[n];
        if (f & 0x02 != 0) { // x-short: 1 byte, positive when 0x10 set
            const v = try r.readU8(pos);
            pos += 1;
            x +|= if (f & 0x10 != 0) @as(i32, v) else -@as(i32, v);
        } else if (f & 0x10 == 0) { // x-same clear: signed 16-bit delta
            x +|= try r.readI16(pos);
            pos += 2;
        }
        points[n].x = @floatFromInt(x);
        points[n].on_curve = f & 0x01 != 0;
    }
    var y: i32 = 0;
    n = 0;
    while (n < n_points) : (n += 1) {
        const f = flags[n];
        if (f & 0x04 != 0) { // y-short: 1 byte, positive when 0x20 set
            const v = try r.readU8(pos);
            pos += 1;
            y +|= if (f & 0x20 != 0) @as(i32, v) else -@as(i32, v);
        } else if (f & 0x20 == 0) { // y-same clear: signed 16-bit delta
            y +|= try r.readI16(pos);
            pos += 2;
        }
        points[n].y = @floatFromInt(y);
    }

    var c_start: usize = 0;
    i = 0;
    while (i < n_contours) : (i += 1) {
        const c_end: usize = ends[i];
        try appendContour(gpa, curves, points[c_start .. c_end + 1]);
        c_start = c_end + 1;
    }
}

/// Decompose one closed contour into quadratic segments (the standard
/// TrueType rule): consecutive on-curve points join by a line (control =
/// midpoint); a lone off-curve point between on-curve positions is the
/// control; consecutive off-curve points imply an on-curve midpoint
/// between them; the contour closes back to its first point. A contour of
/// exactly one point is degenerate (nothing emitted); two points = a line.
fn appendContour(
    gpa: std.mem.Allocator,
    curves: *std.ArrayList(QuadCurve),
    pts: []const GlyphPoint,
) std.mem.Allocator.Error!void {
    const n = pts.len;
    if (n <= 1) return;
    if (n == 2) {
        try curves.append(gpa, .{
            .p0 = xy(pts[0]),
            .p1 = midPoint(xy(pts[0]), xy(pts[1])),
            .p2 = xy(pts[1]),
        });
        return;
    }
    if (n > 0) {
        var start: usize = 0;
        var any_on = false;
        for (pts, 0..) |p, idx| {
            if (p.on_curve) {
                start = idx;
                any_on = true;
                break;
            }
        }
        // Current on-curve position plus the pending off-curve control (at
        // most one: the second of two consecutive off-curves immediately emits
        // their implied midpoint). With no on-curve point at all, the contour
        // starts at the implied midpoint of the last and first points, with the
        // first point pending as the control.
        var cur: [2]f32 = if (any_on) xy(pts[start]) else midPoint(xy(pts[n - 1]), xy(pts[0]));
        var ctrl: ?[2]f32 = if (any_on) null else xy(pts[0]);
        var idx = (start + 1) % n;
        while (true) {
            const p = xy(pts[idx]);
            if (pts[idx].on_curve) {
                if (ctrl) |c| {
                    try curves.append(gpa, .{ .p0 = cur, .p1 = c, .p2 = p });
                } else {
                    try curves.append(gpa, .{ .p0 = cur, .p1 = midPoint(cur, p), .p2 = p });
                }
                cur = p;
                ctrl = null;
            } else {
                if (ctrl) |c| {
                    const mid = midPoint(c, p);
                    try curves.append(gpa, .{ .p0 = cur, .p1 = c, .p2 = mid });
                    cur = mid;
                }
                ctrl = p;
            }
            if (idx == start) break;
            idx = (idx + 1) % n;
        }
    }
}

/// Decode a composite glyph (numberOfContours == -1): component records
/// each naming a glyph plus a transform (word/byte args, optional scale).
/// Component outlines load recursively and append transformed. Point-index
/// args (no ARGS_ARE_XY_VALUES) are used as raw offsets — true point
/// matching needs the parent's accumulated points and is not implemented.
fn loadComposite(
    self: *const FontFace,
    gpa: std.mem.Allocator,
    data: []const u8,
    depth: u32,
    curves: *std.ArrayList(QuadCurve),
) OutlineError!void {
    const r: Reader = .{ .data = data };
    var pos: usize = 10;
    var comp: Outline = .{ .gpa = gpa };
    defer comp.deinit();
    while (true) {
        const flags = try r.readU16(pos);
        pos += 2;
        const comp_gid = try r.readU16(pos);
        pos += 2;

        var dx: i32 = 0;
        var dy: i32 = 0;
        if (flags & 0x0001 != 0) { // ARG_1_AND_2_ARE_WORDS: signed i16
            dx = try r.readI16(pos);
            dy = try r.readI16(pos + 2);
            pos += 4;
        } else { // 1-byte args (unsigned, per the spec)
            dx = try r.readU8(pos);
            dy = try r.readU8(pos + 1);
            pos += 2;
        }

        var sx: f32 = 1;
        var sy: f32 = 1;
        var s01: f32 = 0;
        var s10: f32 = 0;
        if (flags & 0x0008 != 0) { // WE_HAVE_A_SCALE: uniform
            sx = f2dot14(try r.readI16(pos));
            sy = sx;
            pos += 2;
        } else if (flags & 0x0040 != 0) { // WE_HAVE_AN_X_AND_Y_SCALE
            sx = f2dot14(try r.readI16(pos));
            sy = f2dot14(try r.readI16(pos + 2));
            pos += 4;
        } else if (flags & 0x0080 != 0) { // WE_HAVE_A_TWO_BY_TWO
            sx = f2dot14(try r.readI16(pos));
            s01 = f2dot14(try r.readI16(pos + 2));
            s10 = f2dot14(try r.readI16(pos + 4));
            sy = f2dot14(try r.readI16(pos + 6));
            pos += 8;
        }

        // Component outline, transformed into the parent.
        try self.loadGlyph(gpa, comp_gid, depth + 1, &comp.curves);
        const src_curves = comp.curves.items;
        for (src_curves) |c| {
            try curves.append(gpa, .{
                .p0 = transformPoint(c.p0, dx, dy, sx, sy, s01, s10),
                .p1 = transformPoint(c.p1, dx, dy, sx, sy, s01, s10),
                .p2 = transformPoint(c.p2, dx, dy, sx, sy, s01, s10),
            });
        }
        comp.curves.clearRetainingCapacity();

        // MORE_COMPONENTS is spec bit 5 (0x0020); 0x0200 is USE_MY_METRICS,
        // a real flag some fonts set that must NOT chain.
        if (flags & 0x0020 == 0) break;
    }
}

// ── CFF (Type 2 charstring) outline decoding ────────────
// The embedded Latin Modern faces are OpenType/CFF: `OTTO` scaler, a `CFF `
// table, no glyf/loca. CFF glyphs are Type 2 charstrings (Adobe TN 5177)
// executed against the local/global Subr INDEXes. Executed segments are
// flattened to quadratics here — cubics split at t = 0.5 into two
// midpoint-exact quads, lines as midpoint quads — matching the glyf
// decoder's output shape. Semantics follow FreeType's cf2 interpreter
// (src/psaux/psintrp.c); the operand counts and curve geometry were
// verified against fontTools on every glyph of the three embedded faces.

/// Type 2 limits (spec Appendix B): operand stack depth and subr nesting.
const cff_stack_limit = 48;
const max_subr_depth = 10;

/// A parsed CFF INDEX (count, offSize, offsets array, data). Positions are
/// absolute into the font's data; items are located via 1-based offsets.
const CffIndex = struct {
    count: u16,
    off_size: u8,
    /// Absolute offset of the offsets array (count + 1 entries).
    offsets_start: usize,
    /// Absolute offset of the data section.
    data_start: usize,
    /// Absolute offset of the first byte after this INDEX.
    next: usize,
};

/// Read an offSize-byte big-endian offset at `pos` (INDEX offsets).
fn readCffOffset(data: []const u8, pos: usize, off_size: u8) error{InvalidTable}!u32 {
    if (pos + off_size > data.len) return error.InvalidTable;
    var v: u32 = 0;
    var i: u8 = 0;
    while (i < off_size) : (i += 1) v = (v << 8) | data[pos + i];
    return v;
}

/// Parse an INDEX at `pos`; positions are absolute into `data`.
fn parseCffIndex(data: []const u8, pos: usize) error{InvalidTable}!CffIndex {
    const r: Reader = .{ .data = data };
    const count = try r.readU16(pos);
    if (count == 0) {
        // Empty INDEX: no offsets, no data.
        return .{
            .count = 0,
            .off_size = 0,
            .offsets_start = pos + 2,
            .data_start = pos + 2,
            .next = pos + 2,
        };
    }
    const off_size = try r.readU8(pos + 2);
    if (off_size < 1 or off_size > 4) return error.InvalidTable;
    const offsets_start = pos + 3;
    const data_start = offsets_start + (@as(usize, count) + 1) * off_size;
    const last = try readCffOffset(data, offsets_start + @as(usize, count) * off_size, off_size);
    if (last < 1 or data_start + last - 1 > data.len) return error.InvalidTable;
    return .{
        .count = count,
        .off_size = off_size,
        .offsets_start = offsets_start,
        .data_start = data_start,
        .next = data_start + last - 1,
    };
}

/// Item `i` of an INDEX as a slice into `data`.
fn cffItem(self: CffIndex, data: []const u8, i: usize) error{InvalidTable}![]const u8 {
    if (i >= self.count) return error.InvalidTable;
    const o0 = try readCffOffset(data, self.offsets_start + i * self.off_size, self.off_size);
    const o1 = try readCffOffset(data, self.offsets_start + (i + 1) * self.off_size, self.off_size);
    if (o0 < 1 or o1 < o0) return error.InvalidTable;
    const start = self.data_start + o0 - 1;
    const end = self.data_start + o1 - 1;
    if (end > data.len) return error.InvalidTable;
    return data[start..end];
}

/// Number operand encodings: DICTs use the longint (29) form, charstrings
/// the 16.16 fixed (255) form instead.
const CffNumberFormat = enum { dict, charstring };

/// Decode one CFF number operand at `pos` (advancing it). Operator byte
/// values are rejected — this decodes numbers only.
fn readCffNumber(data: []const u8, pos: *usize, format: CffNumberFormat) error{InvalidTable}!f32 {
    const r: Reader = .{ .data = data };
    const b0 = try r.readU8(pos.*);
    if (b0 <= 27) return error.InvalidTable;
    if (b0 == 28) {
        const v = try r.readI16(pos.* + 1);
        pos.* += 3;
        return @floatFromInt(v);
    }
    if (b0 == 29) { // longint (DICT only)
        if (format != .dict) return error.InvalidTable;
        const v = try r.readI32(pos.* + 1);
        pos.* += 5;
        return @floatFromInt(v);
    }
    if (b0 == 30) { // real number (DICT only): nibble-encoded, 0xF ends
        if (format != .dict) return error.InvalidTable;
        var value: f64 = 0;
        var frac_scale: f64 = 1;
        var frac = false;
        var neg = false;
        var exp_active = false;
        var exp_neg = false;
        var exp_val: i32 = 0;
        var bpos = pos.* + 1;
        var ended = false;
        while (!ended) {
            const b = try r.readU8(bpos);
            bpos += 1;
            const hi = b >> 4;
            const lo = b & 0x0F;
            var n: u8 = 0;
            while (n < 2) : (n += 1) {
                const nib = if (n == 0) hi else lo;
                switch (nib) {
                    0...9 => {
                        if (exp_active) {
                            exp_val = exp_val * 10 + @as(i32, nib);
                        } else if (frac) {
                            frac_scale *= 0.1;
                            value += @as(f64, nib) * frac_scale;
                        } else {
                            value = value * 10.0 + @as(f64, nib);
                        }
                    },
                    0xA => frac = true,
                    0xB => { // 'E'
                        exp_active = true;
                        exp_neg = false;
                    },
                    0xC => { // 'E-'
                        exp_active = true;
                        exp_neg = true;
                    },
                    0xE => neg = true,
                    0xF => {
                        ended = true;
                        break;
                    },
                    else => return error.InvalidTable, // 'D' is reserved
                }
            }
        }
        pos.* = bpos;
        const mantissa = if (neg) -value else value;
        const exp = if (exp_neg)
            -@as(f64, @floatFromInt(exp_val))
        else
            @as(f64, @floatFromInt(exp_val));
        return @floatCast(mantissa * std.math.pow(f64, 10.0, exp));
    }
    if (b0 == 31) return error.InvalidTable; // reserved
    if (b0 == 255) { // 16.16 fixed (charstrings only)
        if (format != .charstring) return error.InvalidTable;
        const hi = try r.readI16(pos.* + 1);
        const lo = try r.readU16(pos.* + 3);
        pos.* += 5;
        return @floatCast(@as(f64, @floatFromInt((@as(i32, hi) << 16) | @as(i32, lo))) / 65536.0);
    }
    if (b0 <= 246) { // 32..246: v = b - 139
        pos.* += 1;
        return @as(f32, @floatCast(@as(f64, @floatFromInt(b0)) - 139.0));
    }
    const b1 = try r.readU8(pos.* + 1);
    pos.* += 2;
    if (b0 <= 250) { // 247..250: (b - 247) * 256 + b1 + 108
        return @as(f32, @floatCast(
            @as(f64, @floatFromInt(@as(i32, b0) - 247)) * 256.0 +
                @as(f64, @floatFromInt(b1)) + 108.0,
        ));
    }
    // 251..254: -(b - 251) * 256 - b1 - 108
    return @as(f32, @floatCast(
        -@as(f64, @floatFromInt(@as(i32, b0) - 251)) * 256.0 -
            @as(f64, @floatFromInt(b1)) - 108.0,
    ));
}

/// Which DICT an operator belongs to (opcodes overlap: 0x11 is CharStrings
/// in the Top DICT but 0x13 is Subrs in the Private DICT).
const CffDictKind = enum { top, private };

/// Operand values collected from a Top/Private DICT (DICT numbers are
/// integral; the offsets are absolute CFF-table positions).
const CffDict = struct {
    char_strings: ?usize = null, // Top 0x11
    private_size: ?usize = null, // Top 0x12 (first operand)
    private_off: ?usize = null, // Top 0x12 (second operand)
    is_cid: bool = false, // Top 0x15 (ROS)
    subrs_off: ?usize = null, // Private 0x13
};

/// A CFF DICT integer operand (a non-negative offset/count) converted to
/// usize, clamped so @intFromFloat cannot trap on a corrupt operand.
fn cffInt(x: f32) usize {
    return @intFromFloat(@min(@max(x, 0), @as(f64, @floatFromInt(std.math.maxInt(u32)))));
}

/// Walk a DICT: operands accumulate on a fixed stack; each operator
/// consumes them. Only the operators we need are recorded.
fn parseCffDict(dict: []const u8, kind: CffDictKind, out: *CffDict) error{InvalidTable}!void {
    var ops: [cff_stack_limit]f32 = undefined;
    var n_ops: usize = 0;
    var i: usize = 0;
    while (i < dict.len) {
        const b = dict[i];
        if (b == 12) { // escape operator: none carry operands we need
            i += 1;
            if (i >= dict.len) return error.InvalidTable;
            i += 1;
            n_ops = 0;
        } else if (b <= 21) {
            switch (kind) {
                .top => switch (b) {
                    0x11 => {
                        if (n_ops < 1) return error.InvalidTable;
                        out.char_strings = cffInt(ops[n_ops - 1]);
                    },
                    0x12 => {
                        if (n_ops < 2) return error.InvalidTable;
                        out.private_size = cffInt(ops[n_ops - 2]);
                        out.private_off = cffInt(ops[n_ops - 1]);
                    },
                    0x15 => out.is_cid = true,
                    else => {},
                },
                .private => switch (b) {
                    0x13 => {
                        if (n_ops < 1) return error.InvalidTable;
                        out.subrs_off = cffInt(ops[n_ops - 1]);
                    },
                    else => {},
                },
            }
            n_ops = 0;
            i += 1;
        } else {
            if (n_ops >= ops.len) return error.InvalidTable;
            ops[n_ops] = try readCffNumber(dict, &i, .dict);
            n_ops += 1;
        }
    }
}

/// Parsed CFF font structure (non-CID layout), positions into the face's
/// data. `lsubrs` is absent when the Private DICT declares no Subrs.
const CffData = struct {
    char_strings: CffIndex,
    gsubrs: CffIndex,
    lsubrs: ?CffIndex,
    gsubr_bias: i32,
    lsubr_bias: i32,
};

/// Subroutine bias from the subr count (Type 2 spec §4.7).
fn cffSubrBias(count: u16) i32 {
    if (count < 1240) return 107;
    if (count < 33900) return 1131;
    return 32768;
}

/// Parse the CFF structure: header, Name/Top DICT/String INDEXes, Global
/// Subrs, then the objects the Top DICT points at (CharStrings INDEX,
/// Private DICT with optional local Subrs). Returns whether the Top DICT
/// declares ROS (CID-keyed — outline decoding is then unsupported).
fn parseCffData(data: []const u8, table: TableLoc, out: *CffData) error{InvalidTable}!bool {
    const base = table.offset;
    const r: Reader = .{ .data = data };
    const hdr_size = try r.readU8(base + 2);
    if (hdr_size < 4 or base + hdr_size > data.len) return error.InvalidTable;
    var pos = base + hdr_size;
    const name_idx = try parseCffIndex(data, pos); // Name INDEX: skipped
    pos = name_idx.next;
    const top_idx = try parseCffIndex(data, pos); // Top DICT INDEX
    pos = top_idx.next;
    if (top_idx.count != 1) return error.InvalidTable; // non-CID: one dict
    const top_dict = try cffItem(top_idx, data, 0);
    var dict: CffDict = .{};
    try parseCffDict(top_dict, .top, &dict);
    const cs_off = dict.char_strings orelse return error.InvalidTable;
    if (base + cs_off > data.len) return error.InvalidTable;
    out.char_strings = try parseCffIndex(data, base + cs_off);
    const string_idx = try parseCffIndex(data, pos); // String INDEX: skipped
    out.gsubrs = try parseCffIndex(data, string_idx.next);
    out.gsubr_bias = cffSubrBias(out.gsubrs.count);
    out.lsubrs = null;
    out.lsubr_bias = 107;
    if (dict.private_off) |p_off| {
        const p_size = dict.private_size orelse return error.InvalidTable;
        if (base + p_off + p_size > data.len) return error.InvalidTable;
        const priv_dict = data[base + p_off .. base + p_off + p_size];
        var pd: CffDict = .{};
        try parseCffDict(priv_dict, .private, &pd);
        if (pd.subrs_off) |s_off| {
            out.lsubrs = try parseCffIndex(data, base + p_off + s_off);
            out.lsubr_bias = cffSubrBias(out.lsubrs.?.count);
        }
    }
    return dict.is_cid;
}

/// Type 2 charstring interpreter: executes one glyph's charstring plus its
/// local/global subroutines, appending flattened quadratics to `curves`.
/// State that persists across subr calls (operand stack, stems, width flag,
/// current point) lives here; subr nesting is capped.
const CffInterp = struct {
    gpa: std.mem.Allocator,
    data: []const u8,
    cff: CffData,
    curves: *std.ArrayList(QuadCurve),

    stack: [cff_stack_limit]f32 = undefined,
    n_stack: usize = 0,
    cur: [2]f32 = .{ 0, 0 },
    contour_start: ?[2]f32 = null,
    stem_count: usize = 0,
    width_seen: bool = false,
    depth: usize = 0,

    fn init(
        gpa: std.mem.Allocator,
        data: []const u8,
        cff: CffData,
        curves: *std.ArrayList(QuadCurve),
    ) CffInterp {
        return .{ .gpa = gpa, .data = data, .cff = cff, .curves = curves };
    }

    fn push(self: *CffInterp, v: f32) error{InvalidTable}!void {
        if (self.n_stack >= self.stack.len) return error.InvalidTable;
        self.stack[self.n_stack] = v;
        self.n_stack += 1;
    }

    /// Pop the top operand (a subr index).
    fn pop(self: *CffInterp) f32 {
        self.n_stack -= 1;
        return self.stack[self.n_stack];
    }

    /// Drop the width operand when this is the first stack-clearing
    /// operator and the stack holds one operand more than `required`
    /// (Type 2 spec Note 4). Only the first such operator may carry a
    /// width.
    fn stripWidth(self: *CffInterp, required: usize) void {
        if (!self.width_seen and self.n_stack == required + 1) {
            @memmove(self.stack[0 .. self.n_stack - 1], self.stack[1..self.n_stack]);
            self.n_stack -= 1;
            self.width_seen = true;
        }
    }

    /// hstem/vstem/hstemhm/vstemhm, and the implied stems of
    /// hintmask/cntrmask: 2 operands per stem; an odd count on the first
    /// such operator carries the width (spec Note 4). Stems accumulate
    /// globally so mask sizing stays correct across subr calls.
    fn doStems(self: *CffInterp) error{InvalidTable}!void {
        if (!self.width_seen and self.n_stack % 2 == 1) {
            @memmove(self.stack[0 .. self.n_stack - 1], self.stack[1..self.n_stack]);
            self.n_stack -= 1;
            self.width_seen = true;
        }
        if (self.n_stack % 2 != 0) return error.InvalidTable;
        self.stem_count += self.n_stack / 2;
        self.n_stack = 0;
    }

    /// Close the open contour with a line back to its start (the implicit
    /// closepath); a contour that already returned to its start emits
    /// nothing. The current point is left at the last drawn point — the
    /// next moveto's arguments are relative to it, per the spec.
    fn closeContour(self: *CffInterp) error{ OutOfMemory, InvalidTable }!void {
        if (self.contour_start) |start| {
            if (self.cur[0] != start[0] or self.cur[1] != start[1]) {
                try self.curves.append(self.gpa, .{
                    .p0 = self.cur,
                    .p1 = .{ 0.5 * (self.cur[0] + start[0]), 0.5 * (self.cur[1] + start[1]) },
                    .p2 = start,
                });
            }
            self.contour_start = null;
        }
    }

    /// Start a new contour at the current point plus (dx, dy), closing any
    /// open contour first.
    fn moveto(self: *CffInterp, dx: f32, dy: f32) error{ OutOfMemory, InvalidTable }!void {
        try self.closeContour();
        self.cur = .{ self.cur[0] + dx, self.cur[1] + dy };
        self.contour_start = self.cur;
    }

    /// A line as a degenerate quad (control = midpoint), like the glyf
    /// decoder.
    fn appendLine(self: *CffInterp, p1: [2]f32) error{ OutOfMemory, InvalidTable }!void {
        try self.curves.append(self.gpa, .{
            .p0 = self.cur,
            .p1 = .{ 0.5 * (self.cur[0] + p1[0]), 0.5 * (self.cur[1] + p1[1]) },
            .p2 = p1,
        });
        self.cur = p1;
    }

    /// Append a line relative to the current point.
    fn lineRel(self: *CffInterp, dx: f32, dy: f32) error{ OutOfMemory, InvalidTable }!void {
        try self.appendLine(.{ self.cur[0] + dx, self.cur[1] + dy });
    }

    /// Append a cubic from six relative deltas (each delta relative to the
    /// previous point), flattened to two quadratics.
    fn curveRel(self: *CffInterp, args: *const [6]f32) error{ OutOfMemory, InvalidTable }!void {
        const x = self.cur[0];
        const y = self.cur[1];
        const x1 = x + args[0];
        const y1 = y + args[1];
        try self.appendCubic(
            self.cur,
            .{ x1, y1 },
            .{ x1 + args[2], y1 + args[3] },
            .{ x1 + args[2] + args[4], y1 + args[3] + args[5] },
        );
    }

    /// Flatten one cubic to two midpoint-exact quadratics: split at t = 0.5
    /// via de Casteljau, then fit each half with
    /// Q1 = (3H1 - H0 + 3H2 - H3)/4, which passes exactly through the
    /// cubic's endpoints and midpoint (standard practice).
    fn appendCubic(
        self: *CffInterp,
        a0: [2]f32,
        a1: [2]f32,
        a2: [2]f32,
        a3: [2]f32,
    ) error{ OutOfMemory, InvalidTable }!void {
        const m = [2]f32{
            0.125 * (a0[0] + 3.0 * a1[0] + 3.0 * a2[0] + a3[0]),
            0.125 * (a0[1] + 3.0 * a1[1] + 3.0 * a2[1] + a3[1]),
        };
        const l1 = [2]f32{ 0.5 * (a0[0] + a1[0]), 0.5 * (a0[1] + a1[1]) };
        const l2 = [2]f32{
            0.25 * (a0[0] + 2.0 * a1[0] + a2[0]),
            0.25 * (a0[1] + 2.0 * a1[1] + a2[1]),
        };
        const r1 = [2]f32{
            0.25 * (a1[0] + 2.0 * a2[0] + a3[0]),
            0.25 * (a1[1] + 2.0 * a2[1] + a3[1]),
        };
        const r2 = [2]f32{ 0.5 * (a2[0] + a3[0]), 0.5 * (a2[1] + a3[1]) };
        const ql = [2]f32{
            0.25 * (3.0 * l1[0] - a0[0] + 3.0 * l2[0] - m[0]),
            0.25 * (3.0 * l1[1] - a0[1] + 3.0 * l2[1] - m[1]),
        };
        const qr = [2]f32{
            0.25 * (3.0 * r1[0] - m[0] + 3.0 * r2[0] - a3[0]),
            0.25 * (3.0 * r1[1] - m[1] + 3.0 * r2[1] - a3[1]),
        };
        try self.curves.append(self.gpa, .{ .p0 = a0, .p1 = ql, .p2 = m });
        try self.curves.append(self.gpa, .{ .p0 = m, .p1 = qr, .p2 = a3 });
        self.cur = a3;
    }

    /// Execute a charstring or subr. True = the glyph is finished (endchar,
    /// possibly inside a subr, or a top-level buffer end).
    fn run(
        self: *CffInterp,
        prog: []const u8,
        is_subr: bool,
    ) error{ OutOfMemory, InvalidTable }!bool {
        var pos: usize = 0;
        while (true) {
            if (pos >= prog.len) {
                // Buffer end without return/endchar: FreeType simulates
                // return (subr) or endchar (top-level charstring).
                if (is_subr) return false;
                try self.closeContour();
                return true;
            }
            const b0 = prog[pos];
            if (b0 == 12) { // escape: next byte is the operator
                if (pos + 1 >= prog.len) return error.InvalidTable;
                const done = try self.opEscape(prog[pos + 1]);
                pos += 2;
                if (done) return true;
                continue;
            }
            if (b0 == 28 or b0 >= 32) { // operand
                try self.push(try readCffNumber(prog, &pos, .charstring));
                continue;
            }
            pos += 1;
            if (b0 == 19 or b0 == 20) { // hintmask/cntrmask: mask follows
                const done = try self.op(b0, is_subr);
                pos += (self.stem_count + 7) / 8;
                if (done) return true;
            } else {
                const done = try self.op(b0, is_subr);
                if (done) return true;
            }
        }
    }

    fn op(self: *CffInterp, opcode: u8, is_subr: bool) error{ OutOfMemory, InvalidTable }!bool {
        const s = &self.stack;
        switch (opcode) {
            1, 3, 18, 23 => try self.doStems(), // hstem, vstem, hstemhm, vstemhm
            4 => { // vmoveto
                self.stripWidth(1);
                if (self.n_stack != 1) return error.InvalidTable;
                self.width_seen = true;
                const dy = s[0];
                self.n_stack = 0;
                try self.moveto(0, dy);
            },
            5 => { // rlineto: 2 operands per segment
                if (self.n_stack % 2 != 0) return error.InvalidTable;
                var i: usize = 0;
                while (i < self.n_stack) : (i += 2) try self.lineRel(s[i], s[i + 1]);
                self.n_stack = 0;
            },
            6, 7 => { // hlineto/vlineto: 1 operand per segment, alternating
                var horizontal = opcode == 6;
                var i: usize = 0;
                while (i < self.n_stack) : (i += 1) {
                    const v = s[i];
                    const p0 = self.cur;
                    const p1 = if (horizontal)
                        [2]f32{ p0[0] + v, p0[1] }
                    else
                        [2]f32{ p0[0], p0[1] + v };
                    try self.curves.append(self.gpa, .{
                        .p0 = p0,
                        .p1 = .{ 0.5 * (p0[0] + p1[0]), 0.5 * (p0[1] + p1[1]) },
                        .p2 = p1,
                    });
                    self.cur = p1;
                    horizontal = !horizontal;
                }
                self.n_stack = 0;
            },
            8 => { // rrcurveto: 6 operands per cubic
                if (self.n_stack % 6 != 0) return error.InvalidTable;
                var i: usize = 0;
                while (i < self.n_stack) : (i += 6) try self.curveRel(s[i..][0..6]);
                self.n_stack = 0;
            },
            10, 29 => { // callsubr / callgsubr
                if (self.n_stack == 0) return error.InvalidTable;
                const done = try self.callSubr(self.pop(), opcode == 10);
                if (done) return true;
            },
            11 => { // return
                if (!is_subr) return error.InvalidTable;
                return false;
            },
            14 => { // endchar
                self.width_seen = true;
                try self.closeContour();
                return true;
            },
            19, 20 => try self.doStems(), // hintmask/cntrmask (mask skipped by run)
            21 => { // rmoveto
                self.stripWidth(2);
                if (self.n_stack != 2) return error.InvalidTable;
                self.width_seen = true;
                const dx = s[0];
                const dy = s[1];
                self.n_stack = 0;
                try self.moveto(dx, dy);
            },
            22 => { // hmoveto
                self.stripWidth(1);
                if (self.n_stack != 1) return error.InvalidTable;
                self.width_seen = true;
                const dx = s[0];
                self.n_stack = 0;
                try self.moveto(dx, 0);
            },
            24 => { // rcurveline: 6-operand cubics, then one 2-operand line
                var i: usize = 0;
                while (self.n_stack - i >= 8) : (i += 6) try self.curveRel(s[i..][0..6]);
                if (self.n_stack - i != 2) return error.InvalidTable;
                try self.lineRel(s[i], s[i + 1]);
                self.n_stack = 0;
            },
            25 => { // rlinecurve: 2-operand lines, then one 6-operand cubic
                var i: usize = 0;
                while (self.n_stack - i > 6) : (i += 2) try self.lineRel(s[i], s[i + 1]);
                if (self.n_stack - i != 6) return error.InvalidTable;
                try self.curveRel(s[i..][0..6]);
                self.n_stack = 0;
            },
            26, 27 => try self.vvHh(opcode == 26), // vvcurveto / hhcurveto
            30, 31 => try self.vhHv(opcode == 30), // vhcurveto / hvcurveto
            else => return error.InvalidTable, // reserved / undefined
        }
        return false;
    }

    fn opEscape(self: *CffInterp, esc: u8) error{ OutOfMemory, InvalidTable }!bool {
        const s = &self.stack;
        switch (esc) {
            34 => { // hflex: dx1 dx2 dy2 dx3 dx4 dx5 dx6 → two cubics
                if (self.n_stack != 7) return error.InvalidTable;
                const dx1 = s[0];
                const dx2 = s[1];
                const dy2 = s[2];
                const dx3 = s[3];
                const dx4 = s[4];
                const dx5 = s[5];
                const dx6 = s[6];
                self.n_stack = 0;
                const x = self.cur[0];
                const y = self.cur[1];
                const s1x = x + dx1;
                const s2x = s1x + dx2;
                const s3x = s2x + dx3;
                const s4x = s3x + dx4;
                const s5x = s4x + dx5;
                const s6x = s5x + dx6;
                try self.appendCubic(self.cur, .{ s1x, y }, .{ s2x, y + dy2 }, .{ s3x, y + dy2 });
                try self.appendCubic(
                    .{ s3x, y + dy2 },
                    .{ s4x, y + dy2 },
                    .{ s5x, y },
                    .{ s6x, y },
                );
            },
            35 => { // flex: 12 deltas + flex depth → two cubics
                if (self.n_stack != 13) return error.InvalidTable;
                self.n_stack = 0;
                const x = self.cur[0];
                const y = self.cur[1];
                var px = x;
                var py = y;
                var pts: [6][2]f32 = undefined;
                var i: usize = 0;
                while (i < 6) : (i += 1) {
                    px += s[2 * i];
                    py += s[2 * i + 1];
                    pts[i] = .{ px, py };
                }
                try self.appendCubic(self.cur, pts[0], pts[1], pts[2]);
                try self.appendCubic(pts[2], pts[3], pts[4], pts[5]);
            },
            36 => { // hflex1: dx1 dy1 dx2 dy2 dx3 dx4 dx5 dy5 dx6
                if (self.n_stack != 9) return error.InvalidTable;
                const dx1 = s[0];
                const dy1 = s[1];
                const dx2 = s[2];
                const dy2 = s[3];
                const dx3 = s[4];
                const dx4 = s[5];
                const dx5 = s[6];
                const dy5 = s[7];
                const dx6 = s[8];
                self.n_stack = 0;
                const x = self.cur[0];
                const y = self.cur[1];
                const s1x = x + dx1;
                const s1y = y + dy1;
                const s2x = s1x + dx2;
                const s2y = s1y + dy2;
                const s3x = s2x + dx3;
                const s4x = s3x + dx4;
                const s5x = s4x + dx5;
                const s5y = s2y + dy5;
                const s6x = s5x + dx6;
                try self.appendCubic(self.cur, .{ s1x, s1y }, .{ s2x, s2y }, .{ s3x, s2y });
                try self.appendCubic(.{ s3x, s2y }, .{ s4x, s2y }, .{ s5x, s5y }, .{ s6x, y });
            },
            37 => { // flex1: 10 deltas + d6 (dx or dy by the total displacement)
                if (self.n_stack != 11) return error.InvalidTable;
                self.n_stack = 0;
                const x = self.cur[0];
                const y = self.cur[1];
                var px = x;
                var py = y;
                var pts: [5][2]f32 = undefined;
                var i: usize = 0;
                while (i < 5) : (i += 1) {
                    px += s[2 * i];
                    py += s[2 * i + 1];
                    pts[i] = .{ px, py };
                }
                const dx = pts[4][0] - x;
                const dy = pts[4][1] - y;
                const d6 = s[10];
                const end = if (@abs(dx) > @abs(dy))
                    [2]f32{ x + dx + d6, y }
                else
                    [2]f32{ x, y + dy + d6 };
                try self.appendCubic(self.cur, pts[0], pts[1], pts[2]);
                try self.appendCubic(pts[2], pts[3], pts[4], end);
            },
            else => return error.InvalidTable,
        }
        return false;
    }

    /// vvcurveto (26) / hhcurveto (27): 4 operands per curve plus an
    /// optional leading dx1/dy1 on the first curve (odd count). The count
    /// is normalized like FreeType (`count & ~2`), dropping any leading
    /// junk, so non-canonical stacks never read out of bounds.
    fn vvHh(self: *CffInterp, vertical: bool) error{ OutOfMemory, InvalidTable }!void {
        const s = &self.stack;
        const count1 = self.n_stack;
        const count = count1 & ~@as(usize, 2);
        var idx = count1 - count;
        var x = self.cur[0];
        var y = self.cur[1];
        while (idx < count) : (idx += 4) {
            var lead: f32 = 0;
            if ((count - idx) & 1 != 0) {
                lead = s[idx];
                idx += 1;
            }
            var x1: f32 = undefined;
            var y1: f32 = undefined;
            var x2: f32 = undefined;
            var y2: f32 = undefined;
            var x3: f32 = undefined;
            var y3: f32 = undefined;
            if (vertical) {
                x1 = x + lead; // first control x stays at the start ("v")
                y1 = y + s[idx];
                x2 = x1 + s[idx + 1];
                y2 = y1 + s[idx + 2];
                x3 = x2;
                y3 = y2 + s[idx + 3];
            } else {
                x1 = x + s[idx];
                y1 = y + lead; // first control y stays at the start ("h")
                x2 = x1 + s[idx + 1];
                y2 = y1 + s[idx + 2];
                x3 = x2 + s[idx + 3];
                y3 = y2;
            }
            try self.appendCubic(.{ x, y }, .{ x1, y1 }, .{ x2, y2 }, .{ x3, y3 });
            x = x3;
            y = y3;
        }
        self.cur = .{ x, y };
        self.n_stack = 0;
    }

    /// vhcurveto (30) / hvcurveto (31): 4 operands per curve, alternating
    /// vertical/horizontal first controls; the LAST curve may take a fifth
    /// operand for its final coordinate along the tangent axis. Count is
    /// normalized like FreeType.
    fn vhHv(self: *CffInterp, start_vertical: bool) error{ OutOfMemory, InvalidTable }!void {
        const s = &self.stack;
        const count1 = self.n_stack;
        const count = count1 & ~@as(usize, 2);
        var idx = count1 - count;
        var x = self.cur[0];
        var y = self.cur[1];
        var vertical = start_vertical;
        while (idx < count) {
            const last = count - idx == 5;
            const extra: f32 = if (last) s[idx + 4] else 0;
            var x1: f32 = undefined;
            var y1: f32 = undefined;
            var x2: f32 = undefined;
            var y2: f32 = undefined;
            var x3: f32 = undefined;
            var y3: f32 = undefined;
            if (vertical) {
                x1 = x;
                y1 = y + s[idx];
                x2 = x1 + s[idx + 1];
                y2 = y1 + s[idx + 2];
                x3 = x2 + s[idx + 3];
                y3 = y2 + extra;
            } else {
                x1 = x + s[idx];
                y1 = y;
                x2 = x1 + s[idx + 1];
                y2 = y1 + s[idx + 2];
                x3 = x2 + extra;
                y3 = y2 + s[idx + 3];
            }
            try self.appendCubic(.{ x, y }, .{ x1, y1 }, .{ x2, y2 }, .{ x3, y3 });
            x = x3;
            y = y3;
            idx += if (last) @as(usize, 5) else 4;
            vertical = !vertical;
        }
        self.cur = .{ x, y };
        self.n_stack = 0;
    }

    /// Call a local/global subroutine (biased index); its program runs in
    /// the same interpreter state, so the operand stack, stems, width flag,
    /// and current point persist across the call (FreeType semantics — LM
    /// subrs are macros that may push results for the caller).
    fn callSubr(self: *CffInterp, raw: f32, local: bool) error{ OutOfMemory, InvalidTable }!bool {
        if (self.depth >= max_subr_depth) return error.InvalidTable;
        if (raw != @trunc(raw) or raw < -32768.0 or raw > 32767.0) return error.InvalidTable;
        const index: i32 = @intFromFloat(raw);
        const bias = if (local) self.cff.lsubr_bias else self.cff.gsubr_bias;
        const sub_idx = index + bias;
        if (sub_idx < 0) return error.InvalidTable;
        const subs = if (local)
            (self.cff.lsubrs orelse return error.InvalidTable)
        else
            self.cff.gsubrs;
        const prog = try cffItem(subs, self.data, @intCast(sub_idx));
        self.depth += 1;
        defer self.depth -= 1;
        return self.run(prog, true);
    }
};

/// (face, cp) key for the per-glyph metrics cache.
const CacheKey = struct {
    face: *const FontFace,
    cp: u21,
};

/// Roots probed first by `findFont`, before user dirs and the nix store.
const search_roots = [_][]const u8{
    "/run/current-system/sw/share/fonts",
    "/usr/share/fonts",
    "/usr/local/share/fonts",
    "/nix/var/nix/profiles/default/share/fonts",
};

/// Max recursion depth when walking font directories.
const max_search_depth = 6;

/// Max bytes accepted for a font file read.
const max_font_bytes = 64 * 1024 * 1024;

/// "Init once, render many": owns the embedded fallback faces, caches
/// disk-loaded faces and per-glyph metrics, and memoizes disk discovery.
///
/// Every long-lived allocation lives in `arena` (faces, paths, cache
/// entries); `deinit` releases everything at once. `metrics` is infallible:
/// on an allocation failure it recomputes instead of caching.
pub const FontContext = struct {
    /// Caller's allocator; backs the arena.
    gpa: std.mem.Allocator,
    /// Single arena owns every face, cached path, and cache entry.
    arena: std.heap.ArenaAllocator,
    /// I/O backend for file reads and directory scans. Uses the std
    /// single-threaded instance (file ops need no concurrency here).
    io: std.Io,

    /// Path (arena-owned) → parsed face; dedupes `loadFromFile`.
    faces: std.StringHashMapUnmanaged(*FontFace),
    /// Font name → arena-owned discovered path; empty slice records a miss.
    found: std.StringHashMapUnmanaged([]const u8),
    /// (face, cp) → em metrics at 1pt (scaled by size_pt on return).
    metrics_cache: std.AutoHashMapUnmanaged(CacheKey, GlyphMetrics),

    /// Embedded Latin Modern Math — default face for math glyphs.
    math: *FontFace,
    /// Embedded Latin Modern Roman regular — for \text/\mathrm.
    roman: *FontFace,
    /// Embedded Latin Modern Roman italic.
    italic: *FontFace,

    // TODO(macros): F2 will hang a macro table here (name → expansion).
    // The slot is intentionally reserved; nothing else is needed now.

    /// Create a context preloaded with the embedded fallback faces:
    /// LM Math (math), LM Roman regular and italic (text).
    pub fn init(gpa: std.mem.Allocator) !FontContext {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const math = try createFace(a, lmmath.lmmath_otf[0..]);
        const roman = try createFace(a, lmroman_regular.lmroman10_regular_otf[0..]);
        const italic = try createFace(a, lmroman_italic.lmroman10_italic_otf[0..]);
        return .{
            .gpa = gpa,
            .arena = arena,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .faces = .empty,
            .found = .empty,
            .metrics_cache = .empty,
            .math = math,
            .roman = roman,
            .italic = italic,
        };
    }

    /// Release everything the context owns. Faces loaded via `loadFromFile`
    /// are invalidated; standalone faces created via `FontFace.fromBytes`
    /// are unaffected (they own their own memory).
    pub fn deinit(self: *FontContext) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The embedded Latin Modern Math face (math glyphs).
    pub fn mathFace(self: *const FontContext) *FontFace {
        return self.math;
    }

    /// The embedded Latin Modern Roman face; `italic` selects the italic
    /// variant (for \text/\mathrm).
    pub fn romanFace(self: *const FontContext, italic: bool) *FontFace {
        return if (italic) self.italic else self.roman;
    }

    /// Parse a font file and cache the face by path. Repeated calls with the
    /// same path return the cached face. The face is arena-owned: it lives
    /// until `deinit`. `gpa` is used for the transient read buffer.
    pub fn loadFromFile(self: *FontContext, gpa: std.mem.Allocator, path: []const u8) !*FontFace {
        if (self.faces.get(path)) |face| return face;
        const bytes = try std.Io.Dir.readFileAlloc(.cwd(), self.io, path, gpa, .limited(max_font_bytes));
        defer gpa.free(bytes);
        const face = try createFace(self.arena.allocator(), bytes);
        const key = try self.arena.allocator().dupe(u8, path);
        try self.faces.put(self.arena.allocator(), key, face);
        return face;
    }

    /// Discover a font file on disk by name (basename, case-insensitive, or
    /// prefix of it). Search order: explicit well-known roots, user font
    /// dirs ($XDG_DATA_HOME/fonts, $HOME/.local/share/fonts), the nix store
    /// (/nix/store scan of LM/font packages), then `fc-list` output.
    /// Results (and misses) are memoized per name; the returned path is
    /// arena-owned and valid until `deinit`.
    pub fn findFont(self: *FontContext, name: []const u8) ?[]const u8 {
        if (self.found.get(name)) |cached| {
            return if (cached.len == 0) null else cached;
        }
        const path = self.findFontUncached(name);
        const a = self.arena.allocator();
        const cached_path = a.dupe(u8, path orelse "") catch return path;
        const cached_name = a.dupe(u8, name) catch return path;
        self.found.put(a, cached_name, cached_path) catch return path;
        return path;
    }

    /// Per-glyph metrics at `size_pt` points, cached per (face, cp) in em
    /// units and scaled linearly. Height/depth/line_gap are the face's OWN
    /// nominal extents (hhea) — real font data, never a hard-coded table —
    /// and bound every glyph. Unmapped codepoints get a 0.5em advance with
    /// the same nominal extents (the caller decides how to draw them).
    pub fn metrics(self: *FontContext, face: *const FontFace, cp: u21, size_pt: f32) GlyphMetrics {
        const key: CacheKey = .{ .face = face, .cp = cp };
        const em: GlyphMetrics = if (self.metrics_cache.get(key)) |cached|
            cached
        else blk: {
            const computed = computeEmMetrics(face, cp);
            // metrics() is infallible; a failed insert (OOM) just recomputes.
            self.metrics_cache.put(self.arena.allocator(), key, computed) catch |err| switch (err) {
                error.OutOfMemory => {},
            };
            break :blk computed;
        };
        return .{
            .width = em.width * size_pt,
            .height = em.height * size_pt,
            .depth = em.depth * size_pt,
            .line_gap = em.line_gap * size_pt,
        };
    }

    fn createFace(a: std.mem.Allocator, bytes: []const u8) !*FontFace {
        const owned = try a.dupe(u8, bytes);
        const face = try a.create(FontFace);
        face.* = try parseOwned(owned, null);
        return face;
    }

    fn findFontUncached(self: *FontContext, name: []const u8) ?[]const u8 {
        for (search_roots) |root| {
            if (self.findInTree(root, name, 0)) |p| return p;
        }
        if (self.envGet("XDG_DATA_HOME")) |xdg| {
            if (self.joinAlloc(&.{ xdg, "fonts" })) |dir| {
                if (self.findInTree(dir, name, 0)) |p| return p;
            }
        }
        if (self.envGet("HOME")) |home| {
            if (self.joinAlloc(&.{ home, ".local", "share", "fonts" })) |dir| {
                if (self.findInTree(dir, name, 0)) |p| return p;
            }
        }
        if (self.findInNixStore(name)) |p| return p;
        if (self.findViaFcList(name)) |p| return p;
        return null;
    }

    /// Recursive, depth-limited directory walk looking for `name`.
    fn findInTree(self: *FontContext, root: []const u8, name: []const u8, depth: u32) ?[]const u8 {
        if (depth > max_search_depth) return null;
        var dir = std.Io.Dir.openDir(.cwd(), self.io, root, .{ .iterate = true }) catch return null;
        defer dir.close(self.io);
        var it = dir.iterate();
        while (it.next(self.io) catch return null) |entry| {
            switch (entry.kind) {
                .file => {
                    if (basenameMatches(entry.name, name)) {
                        return self.joinAlloc(&.{ root, entry.name });
                    }
                },
                .directory, .sym_link => {
                    const sub = self.joinAlloc(&.{ root, entry.name }) orelse continue;
                    if (self.findInTree(sub, name, depth + 1)) |p| return p;
                },
                else => {},
            }
        }
        return null;
    }

    /// Scan /nix/store outputs whose name hints at Latin Modern / fonts and
    /// search their share/fonts trees. Store hashes vary per machine, so a
    /// name-filtered walk beats hard-coding them.
    fn findInNixStore(self: *FontContext, name: []const u8) ?[]const u8 {
        var store = std.Io.Dir.openDir(.cwd(), self.io, "/nix/store", .{ .iterate = true }) catch return null;
        defer store.close(self.io);
        var it = store.iterate();
        while (it.next(self.io) catch return null) |entry| {
            if (entry.kind != .directory and entry.kind != .sym_link) continue;
            if (!containsIgnoreCase(entry.name, "lm") and !containsIgnoreCase(entry.name, "font")) continue;
            const share = self.joinAlloc(&.{ "/nix/store", entry.name, "share", "fonts" }) orelse continue;
            if (self.findInTree(share, name, 0)) |p| return p;
        }
        return null;
    }

    /// Query fontconfig (`fc-list`) for a file path matching `name`.
    fn findViaFcList(self: *FontContext, name: []const u8) ?[]const u8 {
        const result = std.process.run(self.arena.allocator(), self.io, .{
            .argv = &.{"fc-list"},
            .stdout_limit = .limited(8 << 20),
            .stderr_limit = .limited(1 << 20),
        }) catch return null;
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const path = std.mem.trim(u8, line[0..colon], " \t");
            if (path.len == 0) continue;
            if (!basenameMatches(path, name)) continue;
            std.Io.Dir.access(.cwd(), self.io, path, .{}) catch continue;
            return self.arena.allocator().dupe(u8, path) catch null;
        }
        return null;
    }

    /// Best-effort environment lookup. Linux reads /proc/self/environ
    /// (dependency-free, no libc); other platforms return null.
    fn envGet(self: *FontContext, key: []const u8) ?[]const u8 {
        if (builtin.os.tag != .linux) return null;
        const data = std.Io.Dir.readFileAlloc(
            .cwd(),
            self.io,
            "/proc/self/environ",
            self.arena.allocator(),
            .limited(1 << 20),
        ) catch return null;
        var it = std.mem.splitScalar(u8, data, 0);
        while (it.next()) |entry| {
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            if (std.mem.eql(u8, entry[0..eq], key)) return entry[eq + 1 ..];
        }
        return null;
    }

    fn joinAlloc(self: *FontContext, parts: []const []const u8) ?[]const u8 {
        return std.fs.path.join(self.arena.allocator(), parts) catch null;
    }
};

/// Em metrics for a codepoint: real advance from hmtx when the glyph exists,
/// nominal extents (hhea) for height/depth/line_gap always; 0.5em advance
/// when the font has no glyph for the codepoint.
fn computeEmMetrics(face: *const FontFace, cp: u21) GlyphMetrics {
    const nominal: GlyphMetrics = .{
        .width = 0.5,
        .height = face.ascenderEm(),
        .depth = face.descenderEm(),
        .line_gap = face.lineGapEm(),
    };
    const gid = face.glyphIndex(cp) orelse return nominal;
    return .{
        .width = face.advanceEm(gid),
        .height = nominal.height,
        .depth = nominal.depth,
        .line_gap = nominal.line_gap,
    };
}

/// Case-insensitive basename match; `name` may also prefix the basename
/// (e.g. "latinmodern-math" matches "latinmodern-math.otf").
fn basenameMatches(candidate: []const u8, name: []const u8) bool {
    const base = std.fs.path.basename(candidate);
    if (std.ascii.eqlIgnoreCase(base, name)) return true;
    if (base.len >= name.len and std.ascii.eqlIgnoreCase(base[0..name.len], name)) return true;
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ── tests ────────────────────────────────
// Expected values below were measured from the real OTF files (fontTools +
// the byte-level parser in this module cross-checked byte-for-byte; see
// notes/font-context.md). Nothing is guessed.

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "font: parse embedded LM Math — upem and nominal extents" {
    var face = try FontFace.fromBytes(testing.allocator, lmmath.lmmath_otf[0..]);
    defer face.deinit();
    try testing.expectEqual(@as(u16, 1000), face.unitsPerEm());
    try testing.expectApproxEqAbs(@as(f32, 0.806), face.ascenderEm(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.194), face.descenderEm(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.200), face.lineGapEm(), 0.001);
    // OS/2 extents of the same font
    try testing.expectApproxEqAbs(@as(f32, 0.806), face.typoAscenderEm(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.194), face.typoDescenderEm(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.200), face.typoLineGapEm(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3.560), face.winAscentEm(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3.060), face.winDescentEm(), 0.001);
}

test "font: cmap + hmtx — real LM Math glyph ids and advances" {
    var face = try FontFace.fromBytes(testing.allocator, lmmath.lmmath_otf[0..]);
    defer face.deinit();
    const x = face.glyphIndex('x') orelse return error.TestUnexpectedResult;
    const n = face.glyphIndex('n') orelse return error.TestUnexpectedResult;
    const sum = face.glyphIndex(0x2211) orelse return error.TestUnexpectedResult;
    const int = face.glyphIndex(0x222B) orelse return error.TestUnexpectedResult;
    // astral-plane coverage comes from the format-12 subtable
    try testing.expect(face.glyphIndex(0x1D400) != null);
    try testing.expectApproxEqAbs(@as(f32, 0.528), face.advanceEm(x), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.556), face.advanceEm(n), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.056), face.advanceEm(sum), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.665), face.advanceEm(int), 0.001);
}

test "font: roman face — format 4 only, no math glyphs" {
    var face = try FontFace.fromBytes(
        testing.allocator,
        lmroman_regular.lmroman10_regular_otf[0..],
    );
    defer face.deinit();
    try testing.expectEqual(@as(u16, 1000), face.unitsPerEm());
    try testing.expectApproxEqAbs(@as(f32, 1.127), face.ascenderEm(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.290), face.descenderEm(), 0.001);
    try testing.expect(face.glyphIndex('x') != null);
    try testing.expect(face.glyphIndex(0x2211) == null);
    try testing.expectApproxEqAbs(
        @as(f32, 0.528),
        face.advanceEm(face.glyphIndex('x').?),
        0.001,
    );
}

test "font: accepts TTF (glyf) scaler as well as OTF (CFF)" {
    const src = lmmath.lmmath_otf[0..];
    const ttf = try testing.allocator.dupe(u8, src);
    defer testing.allocator.free(ttf);
    ttf[0] = 0x00;
    ttf[1] = 0x01;
    ttf[2] = 0x00;
    ttf[3] = 0x00;
    var face = try FontFace.fromBytes(testing.allocator, ttf);
    defer face.deinit();
    try testing.expectApproxEqAbs(
        @as(f32, 0.528),
        face.advanceEm(face.glyphIndex('x').?),
        0.001,
    );
}

test "font: rejects non-sfnt input" {
    try testing.expectError(error.InvalidSfnt, FontFace.fromBytes(testing.allocator, "not a font"));
    try testing.expectError(error.InvalidSfnt, FontFace.fromBytes(testing.allocator, ""));
}

test "font: context loads embedded fallbacks and caches metrics" {
    var ctx = try FontContext.init(testing.allocator);
    defer ctx.deinit();
    const math = ctx.mathFace();
    try testing.expectEqual(@as(u16, 1000), math.unitsPerEm());
    const roman = ctx.romanFace(false);
    const italic = ctx.romanFace(true);
    try testing.expect(roman != italic);

    const g = ctx.metrics(math, 'x', 20);
    try testing.expectApproxEqAbs(@as(f32, 10.56), g.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 16.12), g.height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3.88), g.depth, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 4.00), g.line_gap, 0.001);
    // same key hits the cache; a different size scales linearly
    const g2 = ctx.metrics(math, 'x', 20);
    try testing.expectApproxEqAbs(g.width, g2.width, 0.0001);
    const g3 = ctx.metrics(math, 'x', 10);
    try testing.expectApproxEqAbs(@as(f32, 5.28), g3.width, 0.001);
    // roman and italic advances differ (real font data)
    const rx = roman.glyphIndex('x').?;
    const ix = italic.glyphIndex('x').?;
    try testing.expectApproxEqAbs(@as(f32, 0.528), roman.advanceEm(rx), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.464), italic.advanceEm(ix), 0.001);
}

test "font: metrics for an unmapped codepoint use nominal extents" {
    var ctx = try FontContext.init(testing.allocator);
    defer ctx.deinit();
    const g = ctx.metrics(ctx.mathFace(), 0x10FFFF, 20);
    try testing.expectApproxEqAbs(@as(f32, 10.0), g.width, 0.001); // 0.5em fallback
    try testing.expectApproxEqAbs(@as(f32, 16.12), g.height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3.88), g.depth, 0.001);
}

test "font: loadFromFile parses a cached face from disk" {
    var ctx = try FontContext.init(testing.allocator);
    defer ctx.deinit();
    const path = ctx.findFont("latinmodern-math.otf") orelse return error.TestUnexpectedResult;
    const face = try ctx.loadFromFile(testing.allocator, path);
    try testing.expectApproxEqAbs(
        @as(f32, 0.528),
        face.advanceEm(face.glyphIndex('x').?),
        0.001,
    );
    // second load with the same path returns the cached face
    try testing.expect(face == try ctx.loadFromFile(testing.allocator, path));
}

test "font: findFont discovers the embedded fonts on disk" {
    var ctx = try FontContext.init(testing.allocator);
    defer ctx.deinit();
    const names = [_][]const u8{
        "latinmodern-math.otf",
        "lmroman10-regular.otf",
        "lmroman10-italic.otf",
    };
    for (names) |name| {
        const path = ctx.findFont(name) orelse return error.TestUnexpectedResult;
        try testing.expect(std.mem.endsWith(u8, path, name));
        std.Io.Dir.access(.cwd(), ctx.io, path, .{}) catch return error.TestUnexpectedResult;
    }
    // memoized miss: unknown names are remembered as not-found, and a
    // repeated call stays null (no rescan).
    try testing.expect(ctx.findFont("no-such-font-xyz.otf") == null);
    try testing.expect(ctx.findFont("no-such-font-xyz.otf") == null);
}

// ── outline tests ─────────────────────────────
// The embedded Latin Modern faces are CFF (OTTO scaler, "CFF " table):
// they carry no glyf/loca tables, so their outlines come from the Type 2
// charstring decoder (tested below on the real faces). The tests in this
// section additionally build a small but complete TrueType font in memory —
// the same tables the glyf decoder reads — exercising every path: flag
// repeats, short/same deltas, off-curve runs with implied midpoints,
// composites with a scale transform, degenerate and empty glyphs.

const TPoint = struct { x: i16, y: i16, on: bool };

const TComponent = struct {
    gid: u16,
    dx: i16,
    dy: i16,
    /// Uniform scale (WE_HAVE_A_SCALE); null = no scale.
    scale: ?f32 = null,
};

const TGlyph = struct {
    points: []const TPoint = &.{},
    end_pts: []const u16 = &.{},
    components: []const TComponent = &.{},
};

fn putU16(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: u16) !void {
    try out.appendSlice(gpa, &[_]u8{ @intCast(v >> 8), @intCast(v & 0xFF) });
}

fn putI16(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: i16) !void {
    try putU16(gpa, out, @bitCast(v));
}

fn putU32(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: u32) !void {
    try out.appendSlice(gpa, &[_]u8{
        @intCast(v >> 24),
        @intCast((v >> 16) & 0xFF),
        @intCast((v >> 8) & 0xFF),
        @intCast(v & 0xFF),
    });
}

/// Big-endian u32 at a fixed offset (sfnt fields are big-endian; @bitCast
/// of an integer would use native order).
fn storeU32(out: []u8, off: usize, v: u32) void {
    out[off] = @intCast(v >> 24);
    out[off + 1] = @intCast((v >> 16) & 0xFF);
    out[off + 2] = @intCast((v >> 8) & 0xFF);
    out[off + 3] = @intCast(v & 0xFF);
}

/// Encode one simple glyph: header, endPts, zero instructions, then
/// per-point flags (repeat-compressed) and x/y deltas. Deltas within
/// [-255, 255] use the short encodings, the rest signed 16-bit.
fn buildSimpleGlyph(gpa: std.mem.Allocator, g: TGlyph) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try putI16(gpa, &out, @intCast(g.end_pts.len)); // numberOfContours
    try putI16(gpa, &out, 0); // xMin
    try putI16(gpa, &out, 0); // yMin
    try putI16(gpa, &out, 1000); // xMax
    try putI16(gpa, &out, 1000); // yMax
    for (g.end_pts) |e| try putU16(gpa, &out, e);
    try putU16(gpa, &out, 0); // instructionLength

    var flags: std.ArrayList(u8) = .empty;
    defer flags.deinit(gpa);
    var xs: std.ArrayList(u8) = .empty;
    defer xs.deinit(gpa);
    var ys: std.ArrayList(u8) = .empty;
    defer ys.deinit(gpa);
    var px: i32 = 0;
    var py: i32 = 0;
    for (g.points) |p| {
        var f: u8 = if (p.on) 0x01 else 0;
        const dx: i32 = @as(i32, p.x) - px;
        const dy: i32 = @as(i32, p.y) - py;
        px = p.x;
        py = p.y;
        if (dx != 0 and dx >= -255 and dx <= 255) {
            f |= 0x02;
            if (dx > 0) f |= 0x10;
            try xs.append(gpa, @intCast(@abs(dx)));
        } else if (dx != 0) {
            try putI16(gpa, &xs, @intCast(dx));
        } else {
            f |= 0x10; // x-same: zero delta, no byte
        }
        if (dy != 0 and dy >= -255 and dy <= 255) {
            f |= 0x04;
            if (dy > 0) f |= 0x20;
            try ys.append(gpa, @intCast(@abs(dy)));
        } else if (dy != 0) {
            try putI16(gpa, &ys, @intCast(dy));
        } else {
            f |= 0x20; // y-same: zero delta, no byte
        }
        try flags.append(gpa, f);
    }
    // Repeat-compress runs of identical flags.
    var i: usize = 0;
    while (i < flags.items.len) {
        const f = flags.items[i];
        var run: usize = 1;
        while (i + run < flags.items.len and flags.items[i + run] == f) run += 1;
        if (run > 1) {
            try out.append(gpa, f | 0x08);
            try out.append(gpa, @intCast(run - 1));
        } else {
            try out.append(gpa, f);
        }
        i += run;
    }
    try out.appendSlice(gpa, xs.items);
    try out.appendSlice(gpa, ys.items);
    const value = try out.toOwnedSlice(gpa);
    return value;
}

/// Encode one composite glyph: numberOfContours == -1 plus component
/// records with word args, xy offsets, and an optional uniform scale.
fn buildCompositeGlyph(gpa: std.mem.Allocator, g: TGlyph) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    // Full 10-byte glyf header (numberOfContours + bounding box), same as
    // simple glyphs; component records follow at offset 10.
    try putI16(gpa, &out, -1);
    try putI16(gpa, &out, 0); // xMin
    try putI16(gpa, &out, 0); // yMin
    try putI16(gpa, &out, 1000); // xMax
    try putI16(gpa, &out, 1000); // yMax
    for (g.components, 0..) |c, i| {
        var flags: u16 = 0x0001 | 0x0002; // words + xy offsets
        if (c.scale != null) flags |= 0x0008; // WE_HAVE_A_SCALE
        if (i + 1 < g.components.len) flags |= 0x0020; // MORE_COMPONENTS
        try putU16(gpa, &out, flags);
        try putU16(gpa, &out, c.gid);
        try putI16(gpa, &out, c.dx);
        try putI16(gpa, &out, c.dy);
        if (c.scale) |s| try putI16(gpa, &out, @intFromFloat(s * 16384.0));
    }
    const value = try out.toOwnedSlice(gpa);
    return value;
}

/// n alternating on/off points around (cx, cy) at radius r (n even).
fn circlePoints(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(TPoint),
    cx: i16,
    cy: i16,
    r: i16,
    n: usize,
) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ang: f64 = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) /
            @as(f64, @floatFromInt(n));
        const fx: f32 = @floatCast(
            @as(f64, @floatFromInt(cx)) + @as(f64, @floatFromInt(r)) * @cos(ang),
        );
        const fy: f32 = @floatCast(
            @as(f64, @floatFromInt(cy)) + @as(f64, @floatFromInt(r)) * @sin(ang),
        );
        try out.append(gpa, .{ .x = @intFromFloat(fx), .y = @intFromFloat(fy), .on = i % 2 == 0 });
    }
}

/// Assemble a complete sfnt: head/hhea/hmtx/maxp/cmap (format 4) +
/// long-format loca + glyf. Glyphs: 0 space, 1 'x', 2 'o', 3 'á'
/// (composite), 4 accent, 5 lone point, 6 two-point line.
fn buildTestTtf(gpa: std.mem.Allocator) ![]u8 {
    var circle_outer: std.ArrayList(TPoint) = .empty;
    defer circle_outer.deinit(gpa);
    try circlePoints(gpa, &circle_outer, 500, 500, 400, 12);
    var circle_inner: std.ArrayList(TPoint) = .empty;
    defer circle_inner.deinit(gpa);
    try circlePoints(gpa, &circle_inner, 500, 500, 200, 10);
    // Both circle point lists in one array (runtime concat).
    const circle_pts = try gpa.alloc(TPoint, circle_outer.items.len + circle_inner.items.len);
    defer gpa.free(circle_pts);
    @memcpy(circle_pts[0..circle_outer.items.len], circle_outer.items);
    @memcpy(circle_pts[circle_outer.items.len..], circle_inner.items);
    const glyphs = [_]TGlyph{
        .{}, // 0: space (empty loca range)
        .{ // 1: 'x' — two strokes; off-curve runs, repeated flags, mixed deltas
            .points = &.{
                .{ .x = 0, .y = 0, .on = true },
                .{ .x = 150, .y = 175, .on = false },
                .{ .x = 300, .y = 350, .on = false },
                .{ .x = 600, .y = 700, .on = true },
                .{ .x = 100, .y = 800, .on = true },
                .{ .x = 300, .y = 450, .on = false },
                .{ .x = 500, .y = 100, .on = true },
            },
            .end_pts = &.{ 3, 6 },
        },
        .{ // 2: 'o' — outer 12-pt circle + inner 10-pt circle
            .points = circle_pts,
            .end_pts = &.{ 11, 21 },
        },
        .{ // 3: 'á' — composite: 'x' at origin + scaled accent
            .components = &.{
                .{ .gid = 1, .dx = 0, .dy = 0 },
                .{ .gid = 4, .dx = 50, .dy = 300, .scale = 0.5 },
            },
        },
        .{ // 4: accent — one upward curve
            .points = &.{
                .{ .x = 100, .y = 600, .on = true },
                .{ .x = 200, .y = 700, .on = false },
                .{ .x = 300, .y = 600, .on = true },
            },
            .end_pts = &.{2},
        },
        .{ // 5: lone point (degenerate contour)
            .points = &.{.{ .x = 500, .y = 500, .on = true }},
            .end_pts = &.{0},
        },
        .{ // 6: two points = a line
            .points = &.{
                .{ .x = 100, .y = 100, .on = true },
                .{ .x = 200, .y = 300, .on = true },
            },
            .end_pts = &.{1},
        },
    };

    var glyf: std.ArrayList(u8) = .empty;
    defer glyf.deinit(gpa);
    var loca: std.ArrayList(u8) = .empty;
    defer loca.deinit(gpa);
    for (glyphs) |g| {
        try putU32(gpa, &loca, @intCast(glyf.items.len));
        const blob = if (g.components.len > 0)
            try buildCompositeGlyph(gpa, g)
        else if (g.points.len == 0 and g.end_pts.len == 0)
            try gpa.alloc(u8, 0) // truly empty glyph: zero-length loca range
        else
            try buildSimpleGlyph(gpa, g);
        try glyf.appendSlice(gpa, blob);
        gpa.free(blob);
    }
    try putU32(gpa, &loca, @intCast(glyf.items.len));

    var head: std.ArrayList(u8) = .empty;
    defer head.deinit(gpa);
    try putU32(gpa, &head, 0x00010000); // version
    try putU32(gpa, &head, 0x00010000); // fontRevision
    try putU32(gpa, &head, 0); // checkSumAdjustment
    try putU32(gpa, &head, 0x5F0F3CF5); // magic
    try putU16(gpa, &head, 0); // flags
    try putU16(gpa, &head, 1000); // unitsPerEm
    try putU32(gpa, &head, 0); // created (LongDateTime: two u32 halves)
    try putU32(gpa, &head, 0);
    try putU32(gpa, &head, 0); // modified
    try putU32(gpa, &head, 0);
    try putI16(gpa, &head, 0); // xMin
    try putI16(gpa, &head, 0); // yMin
    try putI16(gpa, &head, 1000); // xMax
    try putI16(gpa, &head, 1000); // yMax
    try putU16(gpa, &head, 0); // macStyle
    try putU16(gpa, &head, 8); // lowestRecPPEM
    try putI16(gpa, &head, 2); // fontDirectionHint
    try putI16(gpa, &head, 1); // indexToLocFormat: long
    try putI16(gpa, &head, 0); // glyphDataFormat

    var hhea: std.ArrayList(u8) = .empty;
    defer hhea.deinit(gpa);
    try putU32(gpa, &hhea, 0x00010000); // version
    try putI16(gpa, &hhea, 800); // ascender
    try putI16(gpa, &hhea, -200); // descender
    try putI16(gpa, &hhea, 200); // lineGap
    try putU16(gpa, &hhea, 0); // advanceWidthMax
    try putI16(gpa, &hhea, 0); // minLeftSideBearing
    try putI16(gpa, &hhea, 0); // minRightSideBearing
    try putI16(gpa, &hhea, 0); // xMaxExtent
    try putI16(gpa, &hhea, 1); // caretSlopeRise
    try putI16(gpa, &hhea, 0); // caretSlopeRun
    try putI16(gpa, &hhea, 0); // caretOffset
    try putI16(gpa, &hhea, 0); // reserved x4
    try putI16(gpa, &hhea, 0);
    try putI16(gpa, &hhea, 0);
    try putI16(gpa, &hhea, 0);
    try putI16(gpa, &hhea, 0); // metricDataFormat
    try putU16(gpa, &hhea, 7); // numHMetrics

    var hmtx: std.ArrayList(u8) = .empty;
    defer hmtx.deinit(gpa);
    for (0..7) |_| {
        try putU16(gpa, &hmtx, 500);
        try putI16(gpa, &hmtx, 0);
    }

    var maxp: std.ArrayList(u8) = .empty;
    defer maxp.deinit(gpa);
    try putU32(gpa, &maxp, 0x00005000); // version 0.5
    try putU16(gpa, &maxp, 7); // numGlyphs

    var cmap: std.ArrayList(u8) = .empty;
    defer cmap.deinit(gpa);
    try putU16(gpa, &cmap, 0); // version
    try putU16(gpa, &cmap, 1); // numTables
    try putU16(gpa, &cmap, 3); // platform
    try putU16(gpa, &cmap, 1); // encoding
    try putU32(gpa, &cmap, 12); // subtable offset
    try putU16(gpa, &cmap, 4); // format
    try putU16(gpa, &cmap, 0); // length (patched below)
    try putU16(gpa, &cmap, 0); // language
    try putU16(gpa, &cmap, 10); // segCountX2 (5 segments)
    try putU16(gpa, &cmap, 8); // searchRange
    try putU16(gpa, &cmap, 2); // entrySelector
    try putU16(gpa, &cmap, 0); // rangeShift
    const segs = [_][3]u16{
        .{ 0x20, 0x20, 0 }, // space → 0
        .{ 0x6F, 0x6F, 2 }, // 'o' → 2
        .{ 0x78, 0x78, 1 }, // 'x' → 1
        .{ 0xE1, 0xE1, 3 }, // 'á' → 3
        .{ 0xFFFF, 0xFFFF, 0 }, // sentinel
    };
    for (segs) |s| try putU16(gpa, &cmap, s[1]); // endCode
    try putU16(gpa, &cmap, 0); // reservedPad
    for (segs) |s| try putU16(gpa, &cmap, s[0]); // startCode
    for (segs) |s| try putU16(gpa, &cmap, s[2] -% s[0]); // idDelta = gid - cp
    for (segs) |_| try putU16(gpa, &cmap, 0); // idRangeOffset
    const cmap_len: u16 = @intCast(cmap.items.len - 12);
    cmap.items[14] = @intCast(cmap_len >> 8);
    cmap.items[15] = @intCast(cmap_len & 0xFF);

    // sfnt directory: 12-byte header + 16-byte records, tables sorted by
    // tag, each 4-byte aligned.
    const tables = [_]struct { tag: [4]u8, data: []const u8 }{
        .{ .tag = [4]u8{ 'c', 'm', 'a', 'p' }, .data = cmap.items },
        .{ .tag = [4]u8{ 'g', 'l', 'y', 'f' }, .data = glyf.items },
        .{ .tag = [4]u8{ 'h', 'e', 'a', 'd' }, .data = head.items },
        .{ .tag = [4]u8{ 'h', 'h', 'e', 'a' }, .data = hhea.items },
        .{ .tag = [4]u8{ 'h', 'm', 't', 'x' }, .data = hmtx.items },
        .{ .tag = [4]u8{ 'l', 'o', 'c', 'a' }, .data = loca.items },
        .{ .tag = [4]u8{ 'm', 'a', 'x', 'p' }, .data = maxp.items },
    };
    var total: usize = 12 + 16 * tables.len;
    for (tables) |t| total += (t.data.len + 3) & ~@as(usize, 3);
    const ttf = try gpa.alloc(u8, total);
    errdefer gpa.free(ttf);
    storeU32(ttf, 0, 0x00010000); // TrueType scaler
    // Header fields for 7 tables: numTables, searchRange 64 (16 × 2^2),
    // entrySelector 2, rangeShift 48 (16 × 7 - 64).
    const num_tables: u16 = @intCast(tables.len);
    ttf[4] = @intCast(num_tables >> 8);
    ttf[5] = @intCast(num_tables & 0xFF);
    ttf[6] = 0;
    ttf[7] = 64;
    ttf[8] = 0;
    ttf[9] = 2;
    ttf[10] = 0;
    ttf[11] = 48;
    var pos: usize = 12;
    var data_off: usize = 12 + 16 * tables.len;
    for (tables) |t| {
        data_off = (data_off + 3) & ~@as(usize, 3);
        ttf[pos..][0..4].* = t.tag;
        storeU32(ttf, pos + 4, 0); // checksum (unchecked)
        storeU32(ttf, pos + 8, @intCast(data_off));
        storeU32(ttf, pos + 12, @intCast(t.data.len));
        pos += 16;
        @memcpy(ttf[data_off..][0..t.data.len], t.data);
        data_off += t.data.len;
    }
    return ttf;
}

test "font: glyphOutline — 'x' has curves, sane bounds, an upward stroke" {
    const ttf = try buildTestTtf(testing.allocator);
    defer testing.allocator.free(ttf);
    var face = try FontFace.fromBytes(testing.allocator, ttf);
    defer face.deinit();
    const gid = face.glyphIndex('x') orelse return error.TestUnexpectedResult;
    var out = try face.glyphOutline(testing.allocator, gid);
    defer out.deinit();
    try testing.expect(out.curves.items.len > 0);
    var saw_up = false;
    for (out.curves.items) |c| {
        for ([_][2]f32{ c.p0, c.p1, c.p2 }) |p| {
            try testing.expect(p[0] >= -300 and p[0] <= 3000);
            try testing.expect(p[1] >= -300 and p[1] <= 3000);
        }
        if (c.p2[1] > c.p0[1]) saw_up = true;
    }
    try testing.expect(saw_up);
}

test "font: glyphOutline — 'o' has two contours worth of curves" {
    const ttf = try buildTestTtf(testing.allocator);
    defer testing.allocator.free(ttf);
    var face = try FontFace.fromBytes(testing.allocator, ttf);
    defer face.deinit();
    const gid = face.glyphIndex('o') orelse return error.TestUnexpectedResult;
    var out = try face.glyphOutline(testing.allocator, gid);
    defer out.deinit();
    // 12-pt outer circle (6 curves) + 10-pt inner counter (5 curves).
    try testing.expect(out.curves.items.len > 8);
}

test "font: glyphOutline — space is an empty outline" {
    const ttf = try buildTestTtf(testing.allocator);
    defer testing.allocator.free(ttf);
    var face = try FontFace.fromBytes(testing.allocator, ttf);
    defer face.deinit();
    const gid = face.glyphIndex(' ') orelse return error.TestUnexpectedResult;
    var out = try face.glyphOutline(testing.allocator, gid);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 0), out.curves.items.len);
}

test "font: glyphOutline — composite 'á' appends transformed components" {
    const ttf = try buildTestTtf(testing.allocator);
    defer testing.allocator.free(ttf);
    var face = try FontFace.fromBytes(testing.allocator, ttf);
    defer face.deinit();
    const gid = face.glyphIndex(0xE1) orelse return error.TestUnexpectedResult;
    var out = try face.glyphOutline(testing.allocator, gid);
    defer out.deinit();
    // 'x' (5 curves) + accent scaled by 0.5 (2 curves).
    try testing.expectEqual(@as(usize, 7), out.curves.items.len);
    // The scaled accent must land at x*0.5+50, y*0.5+300: its control
    // point (200, 700) becomes (150, 650).
    var saw_scaled = false;
    for (out.curves.items) |c| {
        if (c.p1[0] == 150 and c.p1[1] == 650) saw_scaled = true;
    }
    try testing.expect(saw_scaled);
}

test "font: glyphOutline — degenerate glyphs: lone point empty, two points a line" {
    const ttf = try buildTestTtf(testing.allocator);
    defer testing.allocator.free(ttf);
    var face = try FontFace.fromBytes(testing.allocator, ttf);
    defer face.deinit();
    var lone = try face.glyphOutline(testing.allocator, 5);
    defer lone.deinit();
    try testing.expectEqual(@as(usize, 0), lone.curves.items.len);
    var line = try face.glyphOutline(testing.allocator, 6);
    defer line.deinit();
    try testing.expectEqual(@as(usize, 1), line.curves.items.len);
    try testing.expectEqual(@as(f32, 150), line.curves.items[0].p1[0]);
    try testing.expectEqual(@as(f32, 200), line.curves.items[0].p1[1]);
}

test "font: glyphOutline — malformed inputs error, never panic" {
    const ttf = try buildTestTtf(testing.allocator);
    defer testing.allocator.free(ttf);
    var face = try FontFace.fromBytes(testing.allocator, ttf);
    defer face.deinit();

    // Glyph id past the last loca entry.
    try testing.expectError(
        error.InvalidTable,
        face.glyphOutline(testing.allocator, face.num_glyphs),
    );
    // Bad indexToLocFormat.
    face.index_to_loc_format = 2;
    try testing.expectError(error.InvalidTable, face.glyphOutline(testing.allocator, 1));
    face.index_to_loc_format = 1;
    const glyf_loc = try findTable(face.data, tag("glyf"));
    const loca_loc = try findTable(face.data, tag("loca"));
    // Truncated glyph data: claim 32767 contours — the endPts reads run
    // past the glyph's bytes immediately.
    const x_start = std.mem.readInt(u32, face.data[loca_loc.offset + 4 ..][0..4], .big);
    const nc = face.data[glyf_loc.offset + x_start ..][0..2];
    nc[0] = 0x7F;
    nc[1] = 0xFF;
    try testing.expectError(error.InvalidTable, face.glyphOutline(testing.allocator, 1));
    // loca start past the end (4 GiB) → start > end.
    const entry = face.data[loca_loc.offset + 4 ..][0..4];
    entry[0] = 0xFF;
    entry[1] = 0xFF;
    entry[2] = 0xFF;
    entry[3] = 0xFF;
    try testing.expectError(error.InvalidTable, face.glyphOutline(testing.allocator, 1));
    // loca end past the glyf table → end > glyf.len.
    const end_entry = face.data[loca_loc.offset + 8 ..][0..4];
    end_entry[0] = 0xFF;
    end_entry[1] = 0xFF;
    end_entry[2] = 0xFF;
    end_entry[3] = 0xFF;
    try testing.expectError(error.InvalidTable, face.glyphOutline(testing.allocator, 1));

    // A composite that references itself: recursion must be depth-bounded.
    const gid3_offset = std.mem.readInt(u32, face.data[loca_loc.offset + 12 ..][0..4], .big);
    // First component record starts at glyph+10 (after the bbox header):
    // flags u16, then the component gid u16.
    const comp_gid = face.data[glyf_loc.offset + gid3_offset + 12 ..][0..2];
    comp_gid[0] = 0x00;
    comp_gid[1] = 0x03;
    try testing.expectError(error.InvalidTable, face.glyphOutline(testing.allocator, 3));
}

test "font: glyphOutline — embedded CFF 'x' has curves, sane bounds, an upward stroke" {
    // The vendored Latin Modern faces are CFF (`OTTO` scaler, "CFF " table,
    // no loca/glyf): outlines come from Type 2 charstrings. LM em = 1000.
    var face = try FontFace.fromBytes(
        testing.allocator,
        lmroman_regular.lmroman10_regular_otf[0..],
    );
    defer face.deinit();
    try testing.expect(face.is_cff);
    try testing.expect(face.glyf == null);
    try testing.expect(face.cff != null);
    const gid = face.glyphIndex('x') orelse return error.TestUnexpectedResult;
    var out = try face.glyphOutline(testing.allocator, gid);
    defer out.deinit();
    try testing.expect(out.curves.items.len > 0);
    var saw_up = false;
    for (out.curves.items) |c| {
        for ([_][2]f32{ c.p0, c.p1, c.p2 }) |p| {
            try testing.expect(p[0] >= -2000 and p[0] <= 4000);
            try testing.expect(p[1] >= -2000 and p[1] <= 4000);
        }
        if (c.p2[1] > c.p0[1]) saw_up = true;
    }
    try testing.expect(saw_up);
}

test "font: glyphOutline — embedded CFF 'o' has two contours worth of curves" {
    var face = try FontFace.fromBytes(
        testing.allocator,
        lmroman_regular.lmroman10_regular_otf[0..],
    );
    defer face.deinit();
    const gid = face.glyphIndex('o') orelse return error.TestUnexpectedResult;
    var out = try face.glyphOutline(testing.allocator, gid);
    defer out.deinit();
    // Outer bowl plus the inner counter; each cubic flattens to two quads.
    try testing.expect(out.curves.items.len > 8);
}

test "font: glyphOutline — embedded CFF space is an empty outline" {
    var face = try FontFace.fromBytes(
        testing.allocator,
        lmroman_regular.lmroman10_regular_otf[0..],
    );
    defer face.deinit();
    const gid = face.glyphIndex(' ') orelse return error.TestUnexpectedResult;
    var out = try face.glyphOutline(testing.allocator, gid);
    defer out.deinit();
    // The space charstring is only a width plus endchar.
    try testing.expectEqual(@as(usize, 0), out.curves.items.len);
}

test "font: glyphOutline — embedded CFF Math sum glyph decodes" {
    var face = try FontFace.fromBytes(testing.allocator, lmmath.lmmath_otf[0..]);
    defer face.deinit();
    const gid = face.glyphIndex(0x2211) orelse return error.TestUnexpectedResult;
    var out = try face.glyphOutline(testing.allocator, gid);
    defer out.deinit();
    try testing.expect(out.curves.items.len > 0);
    for (out.curves.items) |c| {
        for ([_][2]f32{ c.p0, c.p1, c.p2 }) |p| {
            try testing.expect(p[0] >= -2000 and p[0] <= 4000);
            try testing.expect(p[1] >= -2000 and p[1] <= 4000);
        }
    }
}

test "font: glyphOutline — CFF glyph id out of range errors, never panics" {
    var face = try FontFace.fromBytes(
        testing.allocator,
        lmroman_regular.lmroman10_regular_otf[0..],
    );
    defer face.deinit();
    try testing.expectError(
        error.InvalidTable,
        face.glyphOutline(testing.allocator, face.num_glyphs),
    );
}

test "font: glyphOutline — regular and italic CFF 'x' shapes differ" {
    var reg = try FontFace.fromBytes(
        testing.allocator,
        lmroman_regular.lmroman10_regular_otf[0..],
    );
    defer reg.deinit();
    var ital = try FontFace.fromBytes(
        testing.allocator,
        lmroman_italic.lmroman10_italic_otf[0..],
    );
    defer ital.deinit();
    var a = try reg.glyphOutline(testing.allocator, reg.glyphIndex('x').?);
    defer a.deinit();
    var b = try ital.glyphOutline(testing.allocator, ital.glyphIndex('x').?);
    defer b.deinit();
    try testing.expect(a.curves.items.len > 0);
    try testing.expect(b.curves.items.len > 0);
    // The two faces are distinct: some control point must differ.
    var differ = a.curves.items.len != b.curves.items.len;
    if (!differ) {
        for (a.curves.items, 0..) |c, i| {
            const d = b.curves.items[i];
            if (c.p0[0] != d.p0[0] or c.p0[1] != d.p0[1] or
                c.p1[0] != d.p1[0] or c.p1[1] != d.p1[1] or
                c.p2[0] != d.p2[0] or c.p2[1] != d.p2[1])
            {
                differ = true;
                break;
            }
        }
    }
    try testing.expect(differ);
}
