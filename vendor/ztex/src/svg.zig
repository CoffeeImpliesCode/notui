//! ztex.svg — serialize a draw list into SVG.
//!
//! The draw model uses baseline-anchored coordinates (y = baseline; ascent is
//! negative). SVG is top-down, so this module offsets every primitive down by
//! the draw list's total ascent so all content sits at non-negative y inside
//! the viewBox. Text is emitted with its baseline at `y` (SVG default
//! dominant-baseline is alphabetic).
//!
//! This module renders and writes; it does not lay out. `render` allocates
//! the returned bytes from the allocator it is given and touches no I/O;
//! `writeFile` is the only entry that opens a file, and it does so against
//! the caller `std.Io`.
//!
//! Every attribute value written from a caller-supplied slice is XML-escaped,
//! so `Options.font_family` and `Options.text_font_family` are data, not
//! markup: a quote or ampersand in either reaches the output as an entity
//! and cannot reshape the document.

const std = @import("std");
const layout = @import("ztex.layout");
const draw = layout.draw;
const atom = draw.atom;

/// Frame and font choices for `render` and `writeFile`. The struct is
/// read-only during the call; `padding` is in points, like every other
/// number here.
pub const Options = struct {
    /// Extra margin in points; zero retains the renderer's automatic ink margin.
    padding: f32 = 0,
    /// `null` emits no background rectangle; a color emits an alpha-bearing fill.
    background: ?draw.Color = null,
    /// Borrowed math font-family list; defaults to Latin Modern then serif fallbacks.
    font_family: []const u8 = "Latin Modern Math, Latin Modern Roman, DejaVu Serif, serif",
    /// Borrowed upright font-family list; defaults to Latin Modern Roman then serif fallbacks.
    text_font_family: []const u8 = "Latin Modern Roman, DejaVu Serif, serif",
};

/// SVG font attributes for one CharStyle. Math (italic) runs use the math
/// family, whose glyphs are italic by design; roman/bold runs switch to the
/// upright text family so \text/\mathrm render upright instead of in the
/// math font's italic shapes. font-style is emitted anyway so fallback
/// faces (LM Roman Italic, DejaVu Serif Italic) stay italic when LMMath is
/// missing.
const FontSpec = struct {
    family: []const u8,
    style: []const u8,
    /// css font-weight; empty string = normal
    weight: []const u8,
};

fn fontSpec(style: atom.CharStyle, opts: *const Options) FontSpec {
    return switch (style) {
        .italic => .{ .family = opts.font_family, .style = "italic", .weight = "" },
        .roman => .{ .family = opts.text_font_family, .style = "normal", .weight = "" },
        .bold => .{ .family = opts.text_font_family, .style = "normal", .weight = "bold" },
        // letter variants: LMMath carries blackboard/script/fraktur glyphs;
        // sans/mono map to their dedicated families.
        .bb, .cal, .frak => .{ .family = opts.font_family, .style = "normal", .weight = "" },
        .sans => .{ .family = "DejaVu Sans, sans-serif", .style = "normal", .weight = "" },
        .mono => .{ .family = "DejaVu Sans Mono, monospace", .style = "normal", .weight = "" },
    };
}

/// Serialize a draw list to an SVG string. Caller owns the returned bytes
/// and releases them with `gpa`.
///
/// Allocates only the result; performs no I/O and reads no global state.
/// `Text.bytes` are borrowed for the call only, so a synthesized glyph the
/// draw list owns in its `glyph_arena` must outlive this call, not the
/// result. `error.OutOfMemory` leaves nothing allocated.
pub fn render(gpa: std.mem.Allocator, dl: *const draw.DrawList, opts: Options) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    // Small safety slop so the frame bounds the ink even with minor renderer
    // font-metric variation; kept tight (0.08 x max_size) to match the
    // references' borders (XeTeX preview ~6pt, KaTeX tight). The lineGap
    // below handles the browser line-box descent.
    var max_size: f32 = 0;
    for (dl.items.items) |d| {
        if (d == .text) max_size = @max(max_size, d.text.size);
    }
    const margin = 0.08 * max_size;
    // Latin Modern Math has a 0.2em lineGap that browsers include in the
    // text line-box extent (below the baseline). Bounding only the glyph ink
    // under-shoots the browser's rendering and clips the bottom.
    const linegap = 0.2 * max_size;
    const pad = opts.padding + margin;
    const w = dl.width + 2 * pad;
    const h = dl.height + dl.depth + 2 * pad + linegap;
    const base = dl.height + pad; // baseline offset so top lands at y = pad

    // All layout numbers are points. width/height carry explicit pt units so
    // the output renders at its declared physical size (bare user units would
    // be px = 96/72 × pt, i.e. 0.75×). The viewBox stays unitless: its user
    // units are defined to equal pt by width/height.
    try buf.print(
        gpa,
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}pt\" height=\"{d}pt\" viewBox=\"0 0 {d} {d}\">\n",
        .{ w, h, w, h },
    );
    if (opts.background) |bg| {
        try buf.print(gpa, "<rect width=\"{d}pt\" height=\"{d}pt\" fill=\"#{s}\"/>\n", .{ w, h, colorHex(bg) });
    }

    for (dl.items.items) |d| {
        switch (d) {
            .text => |t| {
                const fs = fontSpec(t.style, &opts);
                try buf.print(
                    gpa,
                    "<text x=\"{d}pt\" y=\"{d}pt\" font-size=\"{d}pt\" font-family=\"",
                    .{ t.x + pad, t.y + base, t.size },
                );
                try escapeAppend(gpa, &buf, fs.family);
                try buf.appendSlice(gpa, "\" font-style=\"");
                try escapeAppend(gpa, &buf, fs.style);
                try buf.append(gpa, '"');
                if (fs.weight.len > 0) {
                    try buf.appendSlice(gpa, " font-weight=\"");
                    try escapeAppend(gpa, &buf, fs.weight);
                    try buf.append(gpa, '"');
                }
                try buf.print(gpa, " fill=\"#{s}\">", .{colorHex(t.color)});
                try escapeAppend(gpa, &buf, t.bytes);
                try buf.append(gpa, '<');
                try buf.appendSlice(gpa, "/text>\n");
            },
            .rect => |r| {
                try buf.print(
                    gpa,
                    "<rect x=\"{d}pt\" y=\"{d}pt\" width=\"{d}pt\" height=\"{d}pt\" fill=\"#{s}\"/>\n",
                    .{ r.x + pad, r.y + base, r.w, r.h, colorHex(r.color) },
                );
            },
            .line => |l| {
                try buf.print(
                    gpa,
                    "<line x1=\"{d}pt\" y1=\"{d}pt\" x2=\"{d}pt\" " ++
                        "y2=\"{d}pt\" stroke=\"#{s}\" stroke-width=\"{d}pt\"/>\n",
                    .{ l.x0 + pad, l.y0 + base, l.x1 + pad, l.y1 + base, colorHex(l.color), l.width },
                );
            },
        }
    }
    try buf.appendSlice(gpa, "</svg>\n");
    return buf.toOwnedSlice(gpa);
}

/// Write the SVG for a draw list to `path`, creating or truncating it.
///
/// `io` must stay valid for the duration of the call and is not retained. On
/// `error.OutOfMemory` no file is opened. File-system failures can leave `path`
/// absent, empty, partially written, or complete; inspect it before recovery.
/// `path` is resolved against the process working
/// directory, and the file the call creates is the caller's to remove.
pub fn writeFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8, dl: *const draw.DrawList, opts: Options) !void {
    const svg = try render(gpa, dl, opts);
    defer gpa.free(svg);
    var file = try std.Io.Dir.createFile(.cwd(), io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, svg);
}

fn colorHex(c: draw.Color) [8]u8 {
    var out: [8]u8 = undefined;
    hexByte(c.r, out[0..2]);
    hexByte(c.g, out[2..4]);
    hexByte(c.b, out[4..6]);
    hexByte(c.a, out[6..8]);
    return out;
}

fn hexByte(v: u8, out: []u8) void {
    const hex = "0123456789abcdef";
    out[0] = hex[v >> 4];
    out[1] = hex[v & 0x0f];
}

/// Parse a color from a name (`white`, `black`, …) or hex (`#RRGGBB[AA]`,
/// hex digits only, alpha defaulting to opaque). Matching is exact and
/// case-sensitive. `null` means "no colour": `none`, `transparent`, a hex
/// string of the wrong length or with a non-hex digit, and any other
/// unrecognised name.
pub fn parseColor(s: []const u8) ?draw.Color {
    if (std.mem.eql(u8, s, "none") or std.mem.eql(u8, s, "transparent")) return null;
    if (s.len > 0 and s[0] == '#') return parseHex(s[1..]);
    const named = [_]struct { name: []const u8, c: draw.Color }{
        .{ .name = "white", .c = .{ .r = 255, .g = 255, .b = 255 } },
        .{ .name = "black", .c = .{ .r = 0, .g = 0, .b = 0 } },
        .{ .name = "red", .c = .{ .r = 255, .g = 0, .b = 0 } },
        .{ .name = "green", .c = .{ .r = 0, .g = 128, .b = 0 } },
        .{ .name = "blue", .c = .{ .r = 0, .g = 0, .b = 255 } },
        .{ .name = "yellow", .c = .{ .r = 255, .g = 255, .b = 0 } },
        .{ .name = "cyan", .c = .{ .r = 0, .g = 255, .b = 255 } },
        .{ .name = "magenta", .c = .{ .r = 255, .g = 0, .b = 255 } },
        .{ .name = "orange", .c = .{ .r = 255, .g = 165, .b = 0 } },
        .{ .name = "gray", .c = .{ .r = 128, .g = 128, .b = 128 } },
        .{ .name = "grey", .c = .{ .r = 128, .g = 128, .b = 128 } },
    };
    for (named) |n| {
        if (std.mem.eql(u8, s, n.name)) return n.c;
    }
    return null;
}

fn parseHex(s: []const u8) ?draw.Color {
    if (s.len != 6 and s.len != 8) return null;
    var c: draw.Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    if (s.len == 8) c.a = std.fmt.parseInt(u8, s[6..8], 16) catch return null;
    c.r = std.fmt.parseInt(u8, s[0..2], 16) catch return null;
    c.g = std.fmt.parseInt(u8, s[2..4], 16) catch return null;
    c.b = std.fmt.parseInt(u8, s[4..6], 16) catch return null;
    return c;
}

/// XML-escape a text or attribute value: `&`, `<`, `>` and `"`. Every value
/// this module writes from a caller slice goes through here.
fn escapeAppend(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try buf.appendSlice(gpa, "&amp;"),
            '<' => try buf.appendSlice(gpa, "&lt;"),
            '>' => try buf.appendSlice(gpa, "&gt;"),
            '"' => try buf.appendSlice(gpa, "&quot;"),
            else => try buf.append(gpa, c),
        }
    }
}

// ── tests ────────────────────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "svg: baseline offset places all content at non-negative y" {
    var dl = draw.DrawList.init(testing.allocator);
    defer dl.deinit();
    // a single char with ascent 8, depth 2, on the baseline
    _ = try dl.add(.{ .text = .{
        .bytes = "x",
        .x = 0,
        .y = 0,
        .size = 10,
        .style = .italic,
        .color = .{ .r = 0, .g = 0, .b = 0 },
        .src_start = 0,
        .src_end = 1,
    } });
    dl.width = 5;
    dl.height = 8;
    dl.depth = 2;
    const svg = try render(testing.allocator, &dl, .{});
    defer testing.allocator.free(svg);
    // baseline offset = height + margin (0.08*size=0.8) = 8.8; frame adds
    // the 0.2em lineGap (2pt) to the height; every coordinate carries pt units
    try std.mem.indexOf(u8, svg, "<text x=\"0.8pt\" y=\"8.8pt\" font-size=\"10pt\"") != null;
}

test "svg: escapes xml-special characters in text" {
    var dl = draw.DrawList.init(testing.allocator);
    defer dl.deinit();
    _ = try dl.add(.{ .text = .{
        .bytes = "a<b&c",
        .x = 0,
        .y = 0,
        .size = 10,
        .style = .italic,
        .color = .{ .r = 0, .g = 0, .b = 0 },
        .src_start = 0,
        .src_end = 5,
    } });
    dl.width = 10;
    dl.height = 5;
    dl.depth = 1;
    const svg = try render(testing.allocator, &dl, .{});
    defer testing.allocator.free(svg);
    try testing.expect(std.mem.indexOf(u8, svg, "a&lt;b&amp;c") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "a<b&c") == null);
}

test "svg: background fills the viewBox" {
    var dl = draw.DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.width = 10;
    dl.height = 5;
    dl.depth = 1;
    const svg = try render(testing.allocator, &dl, .{ .background = .{ .r = 255, .g = 255, .b = 255 } });
    defer testing.allocator.free(svg);
    try testing.expect(std.mem.indexOf(u8, svg, "<rect width=\"10pt\" height=\"6pt\" fill=\"#ffffffff\"/>") != null);
}

test "svg: pt units and per-style fonts on the svg root and text" {
    var dl = draw.DrawList.init(testing.allocator);
    defer dl.deinit();
    _ = try dl.add(.{ .text = .{
        .bytes = "x",
        .x = 0,
        .y = 0,
        .size = 20,
        .style = .italic,
        .color = .{ .r = 0, .g = 0, .b = 0 },
        .src_start = 0,
        .src_end = 1,
    } });
    _ = try dl.add(.{ .text = .{
        .bytes = "hi",
        .x = 10,
        .y = 0,
        .size = 20,
        .style = .roman,
        .color = .{ .r = 0, .g = 0, .b = 0 },
        .src_start = 1,
        .src_end = 3,
    } });
    _ = try dl.add(.{ .text = .{
        .bytes = "b",
        .x = 20,
        .y = 0,
        .size = 20,
        .style = .bold,
        .color = .{ .r = 0, .g = 0, .b = 0 },
        .src_start = 3,
        .src_end = 4,
    } });
    dl.width = 30;
    dl.height = 8;
    dl.depth = 2;
    const svg = try render(testing.allocator, &dl, .{});
    defer testing.allocator.free(svg);
    // root width/height carry pt (margin 0.08*20=1.6 each side => +3.2 wide;
    // height = 8+2+3.2 + lineGap 4 = 17.2); viewBox unitless
    try testing.expect(std.mem.indexOf(u8, svg, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"33.2pt\" " ++
        "height=\"17.2pt\" viewBox=\"0 0 33.2 17.2\">") != null);
    // math (italic) runs: math family + font-style italic
    try testing.expect(std.mem.indexOf(u8, svg, "font-family=\"Latin Modern Math, Latin Modern Roman, " ++
        "DejaVu Serif, serif\" font-style=\"italic\"") != null);
    // \text/\mathrm (roman): upright text family + font-style normal
    try testing.expect(std.mem.indexOf(u8, svg, "font-family=\"Latin Modern Roman, DejaVu Serif, serif\" " ++
        "font-style=\"normal\"") != null);
    // \mathbf: bold weight on the text family
    try testing.expect(std.mem.indexOf(u8, svg, "font-weight=\"bold\"") != null);
}

test "svg: parseColor resolves names and hex" {
    try testing.expectEqual(@as(draw.Color, .{ .r = 255, .g = 255, .b = 255 }), parseColor("white").?);
    try testing.expect(parseColor("none") == null);
    try testing.expect(parseColor("transparent") == null);
    const c = parseColor("#ff8000").?;
    try testing.expectEqual(@as(u8, 255), c.r);
    try testing.expectEqual(@as(u8, 128), c.g);
    try testing.expectEqual(@as(u8, 0), c.b);
    try testing.expectEqual(@as(u8, 255), c.a);
}

test "svg: escapes caller font families written as attribute values" {
    var dl = draw.DrawList.init(testing.allocator);
    defer dl.deinit();
    _ = try dl.add(.{ .text = .{
        .bytes = "x",
        .x = 0,
        .y = 0,
        .size = 10,
        .style = .italic,
        .color = .{ .r = 0, .g = 0, .b = 0 },
        .src_start = 0,
        .src_end = 1,
    } });
    _ = try dl.add(.{ .text = .{
        .bytes = "h",
        .x = 0,
        .y = 0,
        .size = 10,
        .style = .roman,
        .color = .{ .r = 0, .g = 0, .b = 0 },
        .src_start = 1,
        .src_end = 2,
    } });
    dl.width = 5;
    dl.height = 8;
    dl.depth = 2;
    const svg = try render(testing.allocator, &dl, .{
        .font_family = "a\" onload=\"evil&",
        .text_font_family = "b<\"c",
    });
    defer testing.allocator.free(svg);
    // The quote is an entity, so it cannot end the attribute and start a
    // new one; the raw sequence never reaches the document.
    const attr = "font-family=\"a&quot; onload=&quot;evil&amp;\"";
    try testing.expect(std.mem.indexOf(u8, svg, attr) != null);
    try testing.expect(std.mem.indexOf(u8, svg, "font-family=\"b&lt;&quot;c\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "onload=\"evil") == null);
}
