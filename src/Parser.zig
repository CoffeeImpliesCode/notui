//! Terminal input decoder: turns raw bytes into one `Event` at a time.
//!
//! `Parser` holds only the scratch buffer a CSI or kitty key sequence decodes
//! its `Key.text` into, so one instance serves a whole session and allocates
//! nothing itself. A `null` `paste_allocator` disables OSC 52 paste events:
//! the sequence is still consumed, and no paste is produced.
//!
//! Malformed or unsupported control sequences are consumed without an event
//! rather than reported as failures; the only errors are invalid UTF-8 in a
//! ground-state key and a failed paste allocation. Ordinary input decodes to
//! its event, and `ESC` followed by a byte that is not a sequence introducer
//! decodes as an `alt` key press, not as a consumed sequence.
const std = @import("std");
const testing = std.testing;
const Color = @import("color.zig").Color;
const Event = @import("event.zig").Event;
const Key = @import("Key.zig");
const Mouse = @import("Mouse.zig");
const Winsize = @import("event.zig").Winsize;
const width = @import("width.zig");

const log = std.log.scoped(.notui_parser);

const Parser = @This();

/// What one `parse` call produced: the event, if any, and how many bytes of
/// the input it consumed.
///
/// `n` is 0 exactly when the input does not yet hold a complete event — the
/// caller keeps the bytes and calls again. `event` is null with `n` above 0
/// when the bytes were a complete sequence that carries no event, which is
/// how unknown and unsupported sequences are consumed.
pub const Result = struct {
    event: ?Event,
    /// Bytes consumed; always at most `input.len`.
    n: usize,
};

const mouse_bits = struct {
    const motion: u8 = 0b00100000;
    const buttons: u8 = 0b11000011;
    const shift: u8 = 0b00000100;
    const alt: u8 = 0b00001000;
    const ctrl: u8 = 0b00010000;
    const leave: u16 = 0b100000000;
};

/// Scratch the CSI and kitty decoders build `Key.text` in. A `Key` decoded
/// by `parse` borrows this buffer, so the text is only valid until the next
/// `parse` call on the same `Parser`.
buf: [128]u8 = undefined,

/// Decode the first event in `input`, consuming exactly the bytes that event
/// occupies.
///
/// `input` may hold several events and a trailing partial sequence; `Result.n`
/// says how much was consumed and the caller parses the rest. Empty input
/// consumes nothing. A complete control sequence that carries no event (an
/// unknown control sequence, a bracketed-paste delimiter, an unsupported
/// terminal reply) is consumed and reported as a null event, and the bytes
/// after it still parse. `ESC` followed by a byte that is not a sequence
/// introducer is not a sequence: it decodes as an `alt`+codepoint `key_press`
/// that consumes those two bytes.
///
/// A returned `Event.paste` is allocated with `paste_allocator`, and the
/// caller owns and frees it with that same allocator. Passing `null` disables
/// paste events: a complete OSC 52 sequence is still consumed, and the bytes
/// after it still parse.
///
/// Returns `error.InvalidUTF8` when the first ground-state bytes are not a
/// valid UTF-8 sequence, and an allocator error when a paste cannot be
/// decoded. In both cases nothing is consumed. Every other input decodes to
/// an event -- an ordinary key, a mouse report, a capability or cursor reply
/// -- unless it is an incomplete control sequence, which consumes nothing, or
/// a complete but unsupported or malformed one, which is consumed without an
/// event.
pub fn parse(self: *Parser, input: []const u8, paste_allocator: ?std.mem.Allocator) !Result {
    if (input.len == 0) return .{ .event = null, .n = 0 };

    // We gate this for len > 1 so we can detect singular escape key presses
    if (input[0] == 0x1b and input.len > 1) {
        switch (input[1]) {
            0x4F => return parseSs3(input),
            0x50 => return skipUntilSt(input), // DCS
            0x58 => return skipUntilSt(input), // SOS
            0x5B => return parseCsi(input, &self.buf), // CSI
            0x5D => return parseOsc(input, paste_allocator),
            0x5E => return skipUntilSt(input), // PM
            0x5F => return parseApc(input),
            else => {
                // Anything else is an "alt + <char>" keypress
                const key: Key = .{
                    .codepoint = input[1],
                    .mods = .{ .alt = true },
                };
                return .{
                    .event = .{ .key_press = key },
                    .n = 2,
                };
            },
        }
    } else return parseGround(input);
}

/// Decode one ground-state key. `input` is non-empty; `parse` only reaches
/// here when `input[0]` is not an escape introducer, or is a lone `ESC`.
inline fn parseGround(input: []const u8) !Result {
    const b = input[0];
    var n: usize = 1;
    // ground state generates keypresses when parsing input. We
    // generally get ascii characters, but anything less than
    // 0x20 is a Ctrl+<c> keypress. We map these to lowercase
    // ascii characters when we can
    const key: Key = switch (b) {
        0x00 => .{ .codepoint = '@', .mods = .{ .ctrl = true } },
        0x08 => .{ .codepoint = Key.backspace },
        0x09 => .{ .codepoint = Key.tab },
        0x0A => .{ .codepoint = 'j', .mods = .{ .ctrl = true } },
        0x0D => .{ .codepoint = Key.enter },
        0x01...0x07,
        0x0B...0x0C,
        0x0E...0x1A,
        => .{ .codepoint = b + 0x60, .mods = .{ .ctrl = true } },
        0x1B => .{ .codepoint = Key.escape },
        0x7F => .{ .codepoint = Key.backspace },
        else => blk: {
            // The first codepoint is validated here, and the byte length of
            // the whole grapheme comes from the width seam.
            var view = std.unicode.Utf8View.init(input) catch return error.InvalidUTF8;
            var cp_iter = view.iterator();
            // return null if we don't have a valid codepoint
            const first_cp = cp_iter.nextCodepoint() orelse return error.InvalidUTF8;

            n = std.unicode.utf8CodepointSequenceLength(first_cp) catch return error.InvalidUTF8;

            // Check if we have a multi-codepoint grapheme
            var code = first_cp;
            const grapheme_len = width.firstGraphemeLen(input);
            const cp_count = std.unicode.utf8CountCodepoints(input[0..grapheme_len]) catch return error.InvalidUTF8;

            if (grapheme_len > 0) {
                n = grapheme_len;
                if (cp_count > 1) {
                    code = Key.multicodepoint;
                }
            }

            break :blk .{ .codepoint = code, .text = input[0..n] };
        },
    };

    return .{
        .event = .{ .key_press = key },
        .n = n,
    };
}

inline fn parseSs3(input: []const u8) Result {
    if (input.len < 3) {
        return .{
            .event = null,
            .n = 0,
        };
    }
    const key: Key = switch (input[2]) {
        0x1B => return .{
            .event = null,
            .n = 2,
        },
        'A' => .{ .codepoint = Key.up },
        'B' => .{ .codepoint = Key.down },
        'C' => .{ .codepoint = Key.right },
        'D' => .{ .codepoint = Key.left },
        'E' => .{ .codepoint = Key.kp_begin },
        'F' => .{ .codepoint = Key.end },
        'H' => .{ .codepoint = Key.home },
        'P' => .{ .codepoint = Key.f1 },
        'Q' => .{ .codepoint = Key.f2 },
        'R' => .{ .codepoint = Key.f3 },
        'S' => .{ .codepoint = Key.f4 },
        else => {
            log.warn("unhandled ss3: {x}", .{input[2]});
            return .{
                .event = null,
                .n = 3,
            };
        },
    };
    return .{
        .event = .{ .key_press = key },
        .n = 3,
    };
}

/// The kitty graphics probe id used by caps.zig's detect query; a reply
/// carrying this id decodes as Event.cap.kitty_graphics.
const kitty_graphics_probe_id = "i=9931";

inline fn parseApc(input: []const u8) Result {
    if (input.len < 3) {
        return .{
            .event = null,
            .n = 0,
        };
    }
    const end = std.mem.indexOfScalarPos(u8, input, 2, 0x1b) orelse return .{
        .event = null,
        .n = 0,
    };
    if (input.len < end + 1 + 1) {
        return .{
            .event = null,
            .n = 0,
        };
    }
    const sequence = input[0 .. end + 1 + 1];

    // The kitty graphics query reply (APC G i=9931;OK ST) is part of the
    // capability surface and decodes as an Event.cap. Image chunks and
    // transmit data carry no event and are consumed.
    if (parseKittyGraphicsProbeReply(sequence)) {
        return .{
            .event = .{ .cap = .kitty_graphics },
            .n = sequence.len,
        };
    }
    return .{
        .event = null,
        .n = sequence.len,
    };
}

/// True when `sequence` (ESC _ G … ST) is the kitty graphics probe reply:
/// the probe id appears as a whole comma-delimited field and the payload
/// begins with "OK", optionally followed by ";ENV_…".
fn parseKittyGraphicsProbeReply(sequence: []const u8) bool {
    if (sequence.len < 6) return false;
    if (sequence[0] != 0x1b or sequence[1] != '_' or sequence[2] != 'G') return false;
    const semicolon = std.mem.indexOfScalarPos(u8, sequence, 3, ';') orelse return false;
    if (semicolon == 3) return false; // no params
    const params = sequence[3..semicolon];
    const payload = sequence[semicolon + 1 .. sequence.len - 2];
    if (payload.len == 0) return false;

    // Match the id as a whole field so a reply for image 99312 is not
    // mistaken for the probe id 9931.
    var param_it = std.mem.splitScalar(u8, params, ',');
    var id_found = false;
    while (param_it.next()) |param| {
        if (std.mem.eql(u8, param, kitty_graphics_probe_id)) {
            id_found = true;
            break;
        }
    }
    if (!id_found) return false;
    return std.mem.startsWith(u8, payload, "OK");
}

/// Skips sequences until we see an ST (String Terminator, ESC \)
inline fn skipUntilSt(input: []const u8) Result {
    if (input.len < 3) {
        return .{
            .event = null,
            .n = 0,
        };
    }
    const end = std.mem.indexOfScalarPos(u8, input, 2, 0x1b) orelse return .{
        .event = null,
        .n = 0,
    };
    if (input.len < end + 1 + 1) {
        return .{
            .event = null,
            .n = 0,
        };
    }
    const sequence = input[0 .. end + 1 + 1];
    return .{
        .event = null,
        .n = sequence.len,
    };
}

/// Parses an OSC sequence
inline fn parseOsc(input: []const u8, paste_allocator: ?std.mem.Allocator) !Result {
    if (input.len < 3) {
        return .{
            .event = null,
            .n = 0,
        };
    }
    var bel_terminated: bool = false;
    // end is the index of the terminating byte(s) (either the last byte of an
    // ST or BEL)
    const end: usize = blk: {
        const esc_result = skipUntilSt(input);
        if (esc_result.n > 0) break :blk esc_result.n;

        // No escape, could be BEL terminated
        const bel = std.mem.indexOfScalarPos(u8, input, 2, 0x07) orelse return .{
            .event = null,
            .n = 0,
        };
        bel_terminated = true;
        break :blk bel + 1;
    };

    // The complete OSC sequence
    const sequence = input[0..end];

    const null_event: Result = .{ .event = null, .n = sequence.len };

    const semicolon_idx = std.mem.indexOfScalarPos(u8, input, 2, ';') orelse return null_event;
    const ps = std.fmt.parseUnsigned(u8, input[2..semicolon_idx], 10) catch return null_event;

    switch (ps) {
        4 => {
            const color_idx_delim = std.mem.indexOfScalarPos(
                u8,
                input,
                semicolon_idx + 1,
                ';',
            ) orelse return null_event;
            // The palette index is validated but `Color.Report` carries only
            // the colour, so the index itself is dropped.
            const ps_idx = std.fmt.parseUnsigned(
                u8,
                input[semicolon_idx + 1 .. color_idx_delim],
                10,
            ) catch return null_event;
            _ = ps_idx;
            const color_spec = oscField(input, color_idx_delim, sequence.len, bel_terminated) orelse
                return null_event;
            const color = Color.rgbFromSpec(color_spec) catch return null_event;
            const event: Color.Report = .{
                .kind = .osc4,
                .value = .{ color.rgb.r, color.rgb.g, color.rgb.b },
            };
            return .{
                .event = .{ .color_report = event },
                .n = sequence.len,
            };
        },
        10,
        11,
        12,
        => {
            const color_spec = oscField(input, semicolon_idx, sequence.len, bel_terminated) orelse
                return null_event;
            const color = Color.rgbFromSpec(color_spec) catch return null_event;
            const event: Color.Report = .{
                .kind = switch (ps) {
                    10 => .osc10,
                    11 => .osc11,
                    12 => .osc12,
                    else => unreachable,
                },
                .value = .{ color.rgb.r, color.rgb.g, color.rgb.b },
            };
            return .{
                .event = .{ .color_report = event },
                .n = sequence.len,
            };
        },
        52 => {
            if (input[semicolon_idx + 1] != 'c' or
                semicolon_idx + 2 >= sequence.len or input[semicolon_idx + 2] != ';')
                return null_event;
            const gpa = paste_allocator orelse return null_event;
            // `OSC 52 ; c ; <base64>`: the payload begins two bytes after
            // the parameter separator and runs to the terminator. A sequence
            // that ends before the payload does is complete, and carries no
            // paste.
            const payload = oscField(input, semicolon_idx + 2, sequence.len, bel_terminated) orelse
                return null_event;
            const decoder = std.base64.standard.Decoder;
            const size = decoder.calcSizeForSlice(payload) catch return null_event;
            const text = try gpa.alloc(u8, size);
            decoder.decode(text, payload) catch {
                gpa.free(text);
                return null_event;
            };
            log.debug("decoded paste: {s}", .{text});
            return .{
                .event = .{ .paste = text },
                .n = sequence.len,
            };
        },
        else => return null_event,
    }
}

/// The payload of one OSC sequence: `input[start + 1 .. end)`, where `end`
/// is the last byte before the `BEL` or the `ST`. `null` when the sequence
/// ends at or before `start`, so no slice is ever taken out of order.
fn oscField(
    input: []const u8,
    start: usize,
    sequence_len: usize,
    bel_terminated: bool,
) ?[]const u8 {
    const end = if (bel_terminated) sequence_len - 1 else sequence_len - 2;
    const from = start + 1;
    if (from > end) return null;
    return input[from..end];
}

/// Allow scalar text except controls, noncharacters, and private-use keys.
fn isTextCodepoint(cp: u21) bool {
    if (cp > 0x10FFFF) return false;
    if (cp < 0x20) return false; // C0
    if (cp >= 0x7F and cp <= 0x9F) return false; // DEL and C1
    if (cp >= 0xD800 and cp <= 0xDFFF) return false; // surrogates
    if (cp >= 0xE000 and cp <= 0xF8FF) return false; // BMP private use
    if (cp >= 0xF0000 and cp <= 0xFFFFD) return false; // supplementary private use
    if (cp >= 0x100000 and cp <= 0x10FFFD) return false;
    if (cp >= 0xFDD0 and cp <= 0xFDEF) return false; // noncharacters
    if ((cp & 0xFFFE) == 0xFFFE) return false; // noncharacters
    return true;
}

inline fn parseCsi(input: []const u8, text_buf: []u8) Result {
    if (input.len < 3) {
        return .{
            .event = null,
            .n = 0,
        };
    }
    // We start iterating at index 2 to get past the '['
    const sequence = for (input[2..], 2..) |b, i| {
        switch (b) {
            0x40...0xFF => break input[0 .. i + 1],
            else => continue,
        }
    } else return .{ .event = null, .n = 0 };
    const null_event: Result = .{ .event = null, .n = sequence.len };

    // Defensive: the loop below only breaks at index >= 2 (past ESC
    // `[`), so `sequence` is never empty — the guard keeps the final
    // byte access unreachable-but-safe.
    if (sequence.len == 0) return null_event;

    const final = sequence[sequence.len - 1];
    switch (final) {
        'A', 'B', 'C', 'D', 'E', 'F', 'H', 'P', 'Q', 'R', 'S' => {
            // Legacy keys
            // CSI {ABCDEFHPQS}
            // CSI 1 ; modifier:event_type {ABCDEFHPQS}

            // CPR divergence: CSI {row};{col} R is the Cursor Position Report
            // reply (1-indexed). A bare CSI R (no numeric params) stays the
            // legacy F3 key; a numeric sequence with a missing second param is
            // consumed without an event.
            if (final == 'R') {
                var cpr_iter = std.mem.splitScalar(u8, sequence[2 .. sequence.len - 1], ';');
                const row_buf = cpr_iter.next() orelse unreachable; // always at least one field
                if (row_buf.len > 0) {
                    const col_buf = cpr_iter.next() orelse return null_event;
                    const row = std.fmt.parseUnsigned(u16, row_buf, 10) catch return null_event;
                    const col = std.fmt.parseUnsigned(u16, col_buf, 10) catch return null_event;
                    return .{
                        .event = .{ .cpr = .{ .row = row, .col = col } },
                        .n = sequence.len,
                    };
                }
            }

            // Split first into fields delimited by ';'
            var field_iter = std.mem.splitScalar(u8, sequence[2 .. sequence.len - 1], ';');

            // skip the first field
            _ = field_iter.next(); //

            var is_release: bool = false;
            var key: Key = .{
                .codepoint = switch (final) {
                    'A' => Key.up,
                    'B' => Key.down,
                    'C' => Key.right,
                    'D' => Key.left,
                    'E' => Key.kp_begin,
                    'F' => Key.end,
                    'H' => Key.home,
                    'P' => Key.f1,
                    'Q' => Key.f2,
                    'R' => Key.f3,
                    'S' => Key.f4,
                    else => return null_event,
                },
            };

            field2: {
                // modifier_mask:event_type
                const field_buf = field_iter.next() orelse break :field2;
                var param_iter = std.mem.splitScalar(u8, field_buf, ':');
                const modifier_buf = param_iter.next() orelse unreachable;
                const modifier_mask = parseParam(u8, modifier_buf, 1) orelse return null_event;
                key.mods = @bitCast(modifier_mask -| 1);

                if (param_iter.next()) |event_type_buf| {
                    is_release = std.mem.eql(u8, event_type_buf, "3");
                }
            }

            field3: {
                // text_as_codepoint[:text_as_codepoint]
                const field_buf = field_iter.next() orelse break :field3;
                var param_iter = std.mem.splitScalar(u8, field_buf, ':');
                var total: usize = 0;
                while (param_iter.next()) |cp_buf| {
                    const cp = parseParam(u21, cp_buf, null) orelse return null_event;
                    total += std.unicode.utf8Encode(cp, text_buf[total..]) catch return null_event;
                }
                key.text = text_buf[0..total];
            }

            const event: Event = if (is_release) .{ .key_release = key } else .{ .key_press = key };
            return .{
                .event = event,
                .n = sequence.len,
            };
        },
        'Z' => {
            // Legacy keys
            // CSI Z
            return .{
                .event = .{ .key_press = .{
                    .codepoint = Key.tab,
                    .mods = .{ .shift = true },
                } },
                .n = sequence.len,
            };
        },
        '~' => {
            // Legacy keys
            // CSI number ~
            // CSI number ; modifier ~
            // CSI number ; modifier:event_type ; text_as_codepoint ~
            var field_iter = std.mem.splitScalar(u8, sequence[2 .. sequence.len - 1], ';');
            const number_buf = field_iter.next() orelse unreachable; // always will have one field
            const number = parseParam(u16, number_buf, null) orelse return null_event;

            var key: Key = .{
                .codepoint = switch (number) {
                    2 => Key.insert,
                    3 => Key.delete,
                    5 => Key.page_up,
                    6 => Key.page_down,
                    7 => Key.home,
                    8 => Key.end,
                    11 => Key.f1,
                    12 => Key.f2,
                    13 => Key.f3,
                    14 => Key.f4,
                    15 => Key.f5,
                    17 => Key.f6,
                    18 => Key.f7,
                    19 => Key.f8,
                    20 => Key.f9,
                    21 => Key.f10,
                    23 => Key.f11,
                    24 => Key.f12,
                    // bracketed paste delimiters are consumed without an
                    // The pasted bytes arrive as ordinary ground-state keys.
                    200,
                    201,
                    => return null_event,
                    57427 => Key.kp_begin,
                    else => return null_event,
                },
            };

            var is_release: bool = false;
            field2: {
                // modifier_mask:event_type
                const field_buf = field_iter.next() orelse break :field2;
                var param_iter = std.mem.splitScalar(u8, field_buf, ':');
                const modifier_buf = param_iter.next() orelse unreachable;
                const modifier_mask = parseParam(u8, modifier_buf, 1) orelse return null_event;
                key.mods = @bitCast(modifier_mask -| 1);

                if (param_iter.next()) |event_type_buf| {
                    is_release = std.mem.eql(u8, event_type_buf, "3");
                }
            }

            field3: {
                // text_as_codepoint[:text_as_codepoint]
                const field_buf = field_iter.next() orelse break :field3;
                var param_iter = std.mem.splitScalar(u8, field_buf, ':');
                var total: usize = 0;
                while (param_iter.next()) |cp_buf| {
                    const cp = parseParam(u21, cp_buf, null) orelse return null_event;
                    total += std.unicode.utf8Encode(cp, text_buf[total..]) catch return null_event;
                }
                key.text = text_buf[0..total];
            }

            const event: Event = if (is_release) .{ .key_release = key } else .{ .key_press = key };
            return .{
                .event = event,
                .n = sequence.len,
            };
        },

        'I' => return .{ .event = .focus_in, .n = sequence.len },
        'O' => return .{ .event = .focus_out, .n = sequence.len },
        'M', 'm' => return parseMouse(sequence, input),
        'c' => {
            // Primary DA: `caps` reads the DA1 reply params itself, so the
            // sequence carries no event here.
            return null_event;
        },
        'n' => {
            // Device Status Report. Only the cursor position reply (final
            // 'R') decodes here; every other DSR reply is consumed.
            return null_event;
        },
        't' => {
            // XTWINOPS
            // Split first into fields delimited by ';'
            var iter = std.mem.splitScalar(u8, sequence[2 .. sequence.len - 1], ';');
            const ps = iter.first();
            if (std.mem.eql(u8, "48", ps)) {
                // in band window resize
                // CSI 48 ; height ; width ; height_pix ; width_pix t
                const height_char = iter.next() orelse return null_event;
                const width_char = iter.next() orelse return null_event;
                const height_pix = iter.next() orelse "0";
                const width_pix = iter.next() orelse "0";

                const winsize: Winsize = .{
                    .rows = std.fmt.parseUnsigned(u16, height_char, 10) catch return null_event,
                    .cols = std.fmt.parseUnsigned(u16, width_char, 10) catch return null_event,
                    .x_pixel = std.fmt.parseUnsigned(u16, width_pix, 10) catch return null_event,
                    .y_pixel = std.fmt.parseUnsigned(u16, height_pix, 10) catch return null_event,
                };
                return .{
                    .event = .{ .winsize = winsize },
                    .n = sequence.len,
                };
            }
            return null_event;
        },
        'u' => {
            // Kitty keyboard
            // CSI unicode-key-code:alternate-key-codes ; modifiers:event-type ; text-as-codepoints u
            // Not all fields will be present. Only unicode-key-code is
            // mandatory

            // The terminal's capability reply is CSI ? flags u (answer to a
            // CSI ? u query) or CSI > 1 ; flags u (answer to a CSI > flags u
            // push, the form caps.zig uses)
            if (sequence.len > 2 and (sequence[2] == '?' or sequence[2] == '>')) return .{
                .event = .{ .cap = .kitty_keyboard },
                .n = sequence.len,
            };

            var key: Key = .{
                .codepoint = undefined,
            };
            // Split first into fields delimited by ';'
            var field_iter = std.mem.splitScalar(u8, sequence[2 .. sequence.len - 1], ';');

            { // field 1
                // unicode-key-code:shifted_codepoint:base_layout_codepoint
                const field_buf = field_iter.next() orelse unreachable; // There will always be at least one field
                var param_iter = std.mem.splitScalar(u8, field_buf, ':');
                const codepoint_buf = param_iter.next() orelse unreachable;
                key.codepoint = parseParam(u21, codepoint_buf, null) orelse return null_event;

                if (param_iter.next()) |shifted_cp_buf| {
                    key.shifted_codepoint = parseParam(u21, shifted_cp_buf, null);
                }
                if (param_iter.next()) |base_layout_buf| {
                    key.base_layout_codepoint = parseParam(u21, base_layout_buf, null);
                }
            }

            var is_release: bool = false;

            field2: {
                // modifier_mask:event_type
                const field_buf = field_iter.next() orelse break :field2;
                var param_iter = std.mem.splitScalar(u8, field_buf, ':');
                const modifier_buf = param_iter.next() orelse unreachable;
                const modifier_mask = parseParam(u8, modifier_buf, 1) orelse return null_event;
                key.mods = @bitCast(modifier_mask -| 1);

                if (param_iter.next()) |event_type_buf| {
                    is_release = std.mem.eql(u8, event_type_buf, "3");
                }
            }

            field3: {
                // text_as_codepoint[:text_as_codepoint]
                const field_buf = field_iter.next() orelse break :field3;
                var param_iter = std.mem.splitScalar(u8, field_buf, ':');
                var total: usize = 0;
                while (param_iter.next()) |cp_buf| {
                    const cp = parseParam(u21, cp_buf, null) orelse return null_event;
                    total += std.unicode.utf8Encode(cp, text_buf[total..]) catch return null_event;
                }
                key.text = text_buf[0..total];
            }

            {
                // Explicit text wins. Without it, prefer the terminal's
                // shifted codepoint to the Unicode simple uppercase fallback.
                // Only ASCII gets a synthetic shifted_codepoint.
                const mod_test: Key.Modifiers = .{
                    .shift = true,
                    .caps_lock = key.mods.caps_lock,
                    .num_lock = key.mods.num_lock,
                };
                if (key.text == null and
                    key.mods.eql(mod_test) and
                    isTextCodepoint(key.codepoint))
                {
                    const text_cp = key.shifted_codepoint orelse width.toUpper(key.codepoint);
                    if (isTextCodepoint(text_cp)) {
                        // isTextCodepoint excludes invalid Unicode scalars.
                        const n = std.unicode.utf8Encode(text_cp, text_buf) catch |err| {
                            std.debug.panic("invalid text scalar after validation: {t}", .{err});
                        };
                        key.text = text_buf[0..n];
                        if (key.shifted_codepoint == null and key.codepoint < 0x80) {
                            key.shifted_codepoint = text_cp;
                        }
                    }
                }
            }

            const event: Event = if (is_release)
                .{ .key_release = key }
            else
                .{ .key_press = key };

            return .{ .event = event, .n = sequence.len };
        },
        'y' => {
            // DECRPM (CSI ? Ps ; Pm $ y). The `?` private prefix and the `$`
            // trailer delimit the reply parameters, so every slice below stays
            // inside this sequence: a reply that is not that shape is consumed
            // as a null event and the bytes after it still parse.
            if (sequence.len < 5) return null_event;
            if (sequence[2] != '?' or sequence[sequence.len - 2] != '$') return null_event;
            const params = sequence[3 .. sequence.len - 2];
            const delim_idx = std.mem.indexOfScalar(u8, params, ';') orelse return null_event;
            const ps_buf = params[0..delim_idx];
            // `delim_idx` is a `;` inside `params`, so this tail slice is always
            // ordered and holds the whole of `Pm`; an extra `;` is not a
            // decimal number and fails the parse.
            const pm_buf = params[delim_idx + 1 ..];
            const ps = std.fmt.parseUnsigned(u16, ps_buf, 10) catch return null_event;
            const pm = std.fmt.parseUnsigned(u8, pm_buf, 10) catch return null_event;
            switch (ps) {
                // Focus events
                1004 => switch (pm) {
                    0, 4 => return null_event,
                    else => return .{ .event = .{ .cap = .focus_events }, .n = sequence.len },
                },
                // Mouse Pixel reporting
                1016 => switch (pm) {
                    0, 4 => return null_event,
                    else => return .{ .event = .{ .cap = .sgr_pixels }, .n = sequence.len },
                },
                // Bracketed paste
                2004 => switch (pm) {
                    0, 4 => return null_event,
                    else => return .{ .event = .{ .cap = .bracketed_paste }, .n = sequence.len },
                },
                // Synchronized output
                2026 => switch (pm) {
                    0, 4 => return null_event,
                    else => return .{ .event = .{ .cap = .sync_output }, .n = sequence.len },
                },
                // Unicode Core, see https://github.com/contour-terminal/terminal-unicode-core
                2027 => switch (pm) {
                    0, 4 => return null_event,
                    else => return .{ .event = .{ .cap = .unicode_core }, .n = sequence.len },
                },
                // Color scheme reporting is consumed without an event.
                2031 => return null_event,
                else => return null_event,
            }
        },
        'q' => {
            // The kitty multi cursor reply is consumed without an event.
            return null_event;
        },
        else => return null_event,
    }
}

/// Parse a param buffer, returning a default value if the param was empty
inline fn parseParam(comptime T: type, buf: []const u8, default: ?T) ?T {
    if (buf.len == 0) return default;
    return std.fmt.parseInt(T, buf, 10) catch return null;
}

/// Parse a mouse event
inline fn parseMouse(input: []const u8, full_input: []const u8) Result {
    const null_event: Result = .{ .event = null, .n = input.len };
    // Defensive: both decode branches need three bytes or more, so an empty
    // sequence falls through to `else` and yields `null_event`; the guard
    // keeps the tail index in `.type` unreachable-but-safe.
    if (input.len == 0) return null_event;

    var button_mask: u16 = undefined;
    var px: i16 = undefined;
    var py: i16 = undefined;
    var xoff: u16 = 0;
    var yoff: u16 = 0;
    var xterm: bool = undefined;
    if (input.len == 3 and (input[2] == 'M') and full_input.len >= 6) {
        xterm = true;
        button_mask = full_input[3] -| 32;
        px = full_input[4] -| 32;
        py = full_input[5] -| 32;
    } else if (input.len >= 4 and input[2] == '<') {
        xterm = false;
        const delim1 = std.mem.indexOfScalarPos(u8, input, 3, ';') orelse return null_event;
        button_mask = parseParam(u16, input[3..delim1], null) orelse return null_event;
        const delim2 = std.mem.indexOfScalarPos(u8, input, delim1 + 1, ';') orelse return null_event;
        px = parseParam(i16, input[delim1 + 1 .. delim2], 1) orelse return null_event;
        // SGR 1016 pixel reporting appends `;xoffset;yoffset` after the y
        // param; SGR 1006 ends at the y param.
        const after_y = delim2 + 1;
        if (std.mem.findScalarPos(u8, input, after_y, ';')) |delim3| {
            py = parseParam(i16, input[after_y..delim3], 1) orelse return null_event;
            const delim4 = std.mem.findScalarPos(u8, input, delim3 + 1, ';') orelse return null_event;
            xoff = parseParam(u16, input[delim3 + 1 .. delim4], 0) orelse return null_event;
            yoff = parseParam(u16, input[delim4 + 1 .. input.len - 1], 0) orelse return null_event;
        } else {
            py = parseParam(i16, input[after_y .. input.len - 1], 1) orelse return null_event;
        }
    } else {
        return null_event;
    }
    // A mouse-leave report carries no button or position and is consumed.
    if (button_mask & mouse_bits.leave > 0)
        return .{ .event = null, .n = if (xterm) 6 else input.len };

    const button: Mouse.Button = @fromBackingInt(@intCast(button_mask & mouse_bits.buttons));
    const motion = button_mask & mouse_bits.motion > 0;
    const shift = button_mask & mouse_bits.shift > 0;
    const alt = button_mask & mouse_bits.alt > 0;
    const ctrl = button_mask & mouse_bits.ctrl > 0;

    const mouse: Mouse = .{
        .button = button,
        .mods = .{
            .shift = shift,
            .alt = alt,
            .ctrl = ctrl,
        },
        // 1-based → 0-based. The xterm decode saturates below 32 (px/py = 0),
        // and `-|` on i16 would yield -1 (representable), so clamp xterm coords
        // at 0; SGR coords keep their (deliberately) signed values.
        .col = if (xterm) @max(px -| 1, 0) else px -| 1,
        .row = if (xterm) @max(py -| 1, 0) else py -| 1,
        .xoffset = xoff,
        .yoffset = yoff,
        .type = blk: {
            if (motion and button != Mouse.Button.none) {
                break :blk .drag;
            }
            if (motion and button == Mouse.Button.none) {
                break :blk .motion;
            }
            if (xterm) {
                if (button == Mouse.Button.none) {
                    break :blk .release;
                }
                break :blk .press;
            }
            if (input.len > 0 and input[input.len - 1] == 'm') break :blk .release;
            break :blk .press;
        },
    };
    return .{ .event = .{ .mouse = mouse }, .n = if (xterm) 6 else input.len };
}

test "parse: single xterm keypress" {
    const alloc = testing.allocator_instance.allocator();
    const input = "a";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{
        .codepoint = 'a',
        .text = "a",
    };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(1, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: single xterm keypress backspace" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x08";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{
        .codepoint = Key.backspace,
    };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(1, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: single xterm keypress with more buffer" {
    const alloc = testing.allocator_instance.allocator();
    const input = "ab";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{
        .codepoint = 'a',
        .text = "a",
    };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(1, result.n);
    try testing.expectEqualStrings(expected_key.text.?, result.event.?.key_press.text.?);
    try testing.expectEqualDeep(expected_event, result.event);
}

test "parse: xterm escape keypress" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{ .codepoint = Key.escape };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(1, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: xterm ctrl+a" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x01";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{ .codepoint = 'a', .mods = .{ .ctrl = true } };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(1, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: xterm alt+a" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1ba";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{ .codepoint = 'a', .mods = .{ .alt = true } };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(2, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: xterm key up" {
    const alloc = testing.allocator_instance.allocator();
    {
        // normal version
        const input = "\x1b[A";
        var parser: Parser = .{};
        const result = try parser.parse(input, alloc);
        const expected_key: Key = .{ .codepoint = Key.up };
        const expected_event: Event = .{ .key_press = expected_key };

        try testing.expectEqual(3, result.n);
        try testing.expectEqual(expected_event, result.event);
    }

    {
        // application keys version
        const input = "\x1bOA";
        var parser: Parser = .{};
        const result = try parser.parse(input, alloc);
        const expected_key: Key = .{ .codepoint = Key.up };
        const expected_event: Event = .{ .key_press = expected_key };

        try testing.expectEqual(3, result.n);
        try testing.expectEqual(expected_event, result.event);
    }
}

test "parse: xterm shift+up" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b[1;2A";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{ .codepoint = Key.up, .mods = .{ .shift = true } };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(6, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: xterm shift+tab" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b[Z";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{ .codepoint = Key.tab, .mods = .{ .shift = true } };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(3, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: xterm insert" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b[2~";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{ .codepoint = Key.insert, .mods = .{} };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(input.len, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: paste_start (dropped tag: consumed, no event)" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b[200~";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_event: ?Event = null;

    try testing.expectEqual(6, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: paste_end (dropped tag: consumed, no event)" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b[201~";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_event: ?Event = null;

    try testing.expectEqual(6, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: osc52 paste" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b]52;c;b3NjNTIgcGFzdGU=\x1b\\";
    const expected_text = "osc52 paste";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);

    try testing.expectEqual(25, result.n);
    switch (result.event.?) {
        .paste => |text| {
            defer alloc.free(text);
            try testing.expectEqualStrings(expected_text, text);
        },
        else => try testing.expect(false),
    }
}

test "parse: osc52 paste with bel terminator" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b]52;c;b3NjNTIgcGFzdGU=\x07";
    const expected_text = "osc52 paste";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);

    try testing.expectEqual(24, result.n);
    switch (result.event.?) {
        .paste => |text| {
            defer alloc.free(text);
            try testing.expectEqualStrings(expected_text, text);
        },
        else => try testing.expect(false),
    }
}

test "parse: osc52 paste is dropped when paste_allocator is null" {
    // A null paste_allocator is how a caller opts out of clipboard
    // decoding. The paste bytes must then vanish without an event, and
    // without eating whatever key the terminal sent next.
    const cases = [_]struct {
        sequence: []const u8,
        len: usize,
    }{
        .{ .sequence = "\x1b]52;c;b3NjNTIgcGFzdGU=\x1b\\", .len = 25 },
        .{ .sequence = "\x1b]52;c;b3NjNTIgcGFzdGU=\x07", .len = 24 },
        .{ .sequence = "\x1b]52;c;\x07", .len = 8 },
    };
    for (cases) |case| {
        var input_buf: [32]u8 = undefined;
        const input = try std.fmt.bufPrint(&input_buf, "{s}A", .{case.sequence});
        var parser: Parser = .{};
        const result = try parser.parse(input, null);

        try testing.expect(result.event == null);
        try testing.expectEqual(case.len, result.n);

        const rest = try parser.parse(input[result.n..], null);
        try testing.expectEqual(1, rest.n);
        const expected_key: u21 = 'A';
        try testing.expectEqual(expected_key, rest.event.?.key_press.codepoint);
    }
}

test "parse: incomplete osc52 paste consumes nothing until terminated" {
    // Without a terminator there is nothing to decode yet, so the parser
    // must take no bytes and let the caller feed the same prefix again.
    const partials = [_][]const u8{
        "\x1b]52;c;b3NjNTIgcGFzdGU=",
        "\x1b]52;c;b3NjNTIgcGFzdGU=\x1b",
    };
    for (partials) |partial| {
        var parser: Parser = .{};
        const result = try parser.parse(partial, null);

        try testing.expect(result.event == null);
        try testing.expectEqual(@as(usize, 0), result.n);
    }

    // Once the terminator arrives the same bytes are a complete sequence.
    const complete = "\x1b]52;c;b3NjNTIgcGFzdGU=\x1b\\";
    var parser: Parser = .{};
    const result = try parser.parse(complete, null);

    try testing.expect(result.event == null);
    try testing.expectEqual(25, result.n);
}

test "parse: empty input consumes nothing and is not an error" {
    var parser: Parser = .{};
    const result = try parser.parse("", testing.allocator);
    try testing.expectEqual(@as(usize, 0), result.n);
    try testing.expect(result.event == null);
}

test "parse: a truncated osc52 payload is consumed without an event" {
    // `ESC ] 52 ; c` with a terminator but no payload separator is a
    // complete sequence carrying nothing; it must not slice backwards
    // through the parameter, and it must not eat the key after it.
    for ([_][]const u8{ "\x1b]52;c\x1b\\", "\x1b]52;c\x07", "\x1b]52;cX\x07" }) |sequence| {
        var input_buf: [32]u8 = undefined;
        const input = try std.fmt.bufPrint(&input_buf, "{s}A", .{sequence});
        var parser: Parser = .{};
        const result = try parser.parse(input, testing.allocator);

        try testing.expect(result.event == null);
        try testing.expectEqual(sequence.len, result.n);

        const rest = try parser.parse(input[result.n..], testing.allocator);
        try testing.expectEqual(@as(usize, 1), rest.n);
        try testing.expectEqual(@as(u21, 'A'), rest.event.?.key_press.codepoint);
    }
}

test "parse: an empty clipboard reply carries an empty paste" {
    var parser: Parser = .{};
    const sequence = "\x1b]52;c;\x07";
    const result = try parser.parse(sequence, testing.allocator);
    const text = result.event.?.paste;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("", text);
    try testing.expectEqual(sequence.len, result.n);
}

test "parse: an undecodable osc52 payload is consumed without an event" {
    // Base64 that does not decode is not an error for the caller: the
    // sequence is complete, so it is consumed and produces no paste.
    for ([_][]const u8{ "\x1b]52;c;!!!!\x1b\\", "\x1b]52;c;QQ\x1b\\" }) |input| {
        var parser: Parser = .{};
        const result = try parser.parse(input, testing.allocator);
        try testing.expect(result.event == null);
        try testing.expectEqual(input.len, result.n);
    }
}

test "parse: a malformed osc colour reply is consumed without an event" {
    // The reply is syntactically complete but its colour spec is not, so
    // there is no report to emit — and the next key still parses.
    const cases = [_][]const u8{
        "\x1b]11;rgb:ffzz/0000/0000\x1b\\",
        "\x1b]11;rgb:00/00/00\x1b\\",
        "\x1b]11;rgbi:0000/0000/0000/ffff\x1b\\",
        "\x1b]11;rgb:aaaa/bbbb/cccc/dddd\x1b\\",
        "\x1b]4;7;rgb:ffzz/0000/0000\x1b\\",
    };
    for (cases) |sequence| {
        var input_buf: [48]u8 = undefined;
        const input = try std.fmt.bufPrint(&input_buf, "{s}A", .{sequence});
        var parser: Parser = .{};
        const result = try parser.parse(input, testing.allocator);

        try testing.expect(result.event == null);
        try testing.expectEqual(sequence.len, result.n);

        const rest = try parser.parse(input[result.n..], testing.allocator);
        try testing.expectEqual(@as(usize, 1), rest.n);
        try testing.expectEqual(@as(u21, 'A'), rest.event.?.key_press.codepoint);
    }
}

test "parse: focus_in" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b[I";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_event: Event = .focus_in;

    try testing.expectEqual(3, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: focus_out" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b[O";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_event: Event = .focus_out;

    try testing.expectEqual(3, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: kitty: shift+a without text reporting" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b[97:65;2u";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{
        .codepoint = 'a',
        .shifted_codepoint = 'A',
        .mods = .{ .shift = true },
        .text = "A",
    };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(10, result.n);
    try testing.expectEqualDeep(expected_event, result.event);
}

test "parse: kitty: shift+non-ascii without text reporting synthesizes text" {
    // A non-ASCII layout reports the base codepoint and, unless the
    // terminal sends a text field, nothing else. `text` is
    // reconstructed from the zg seam so `Key.matchText` — which folds
    // case through the same seam — can match a declared binding.
    const alloc = testing.allocator_instance.allocator();
    // CSI 228 ; 2 u: U+00E4 (a with diaeresis) with shift, no text.
    const input = "\x1b[228;2u";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const key = result.event.?.key_press;

    try testing.expectEqual(@as(u21, 0x00E4), key.codepoint);
    try testing.expectEqualStrings("\u{00C4}", key.text.?);
    // The shifted codepoint is the layout's business, not a case
    // mapping's: a non-ASCII key gets none invented.
    try testing.expect(key.shifted_codepoint == null);
    try testing.expect(key.matchText(0x00E4, .{ .shift = true }));
}

test "parse: kitty: reported text and shifted codepoints take precedence" {
    const cases = [_]struct {
        input: []const u8,
        shifted: u21,
        text: []const u8,
    }{
        .{ .input = "\x1b[97:66;2u", .shifted = 'B', .text = "B" },
        .{ .input = "\x1b[228:214;2u", .shifted = 0x00D6, .text = "\u{00D6}" },
        .{ .input = "\x1b[228:214;2;88u", .shifted = 0x00D6, .text = "X" },
    };
    for (cases) |case| {
        var parser: Parser = .{};
        const result = try parser.parse(case.input, null);
        const key = result.event.?.key_press;

        try testing.expectEqual(case.input.len, result.n);
        try testing.expectEqual(case.shifted, key.shifted_codepoint);
        try testing.expectEqualStrings(case.text, key.text.?);
    }
}

test "parse: kitty: noncharacters and out-of-range codepoints have no synthesized text" {
    const codepoints = [_]u21{
        0xFDD0,   0xFDEF,   0xFFFE,   0xFFFF,             0x1FFFE,              0x1FFFF,
        0x10FFFE, 0x10FFFF, 0x110000, Key.multicodepoint, std.math.maxInt(u21),
    };
    for (codepoints) |cp| {
        var input_buf: [32]u8 = undefined;
        const input = try std.fmt.bufPrint(&input_buf, "\x1b[{d};2u", .{cp});
        var parser: Parser = .{};
        const result = try parser.parse(input, null);
        const key = result.event.?.key_press;

        try testing.expectEqual(input.len, result.n);
        try testing.expectEqual(cp, key.codepoint);
        try testing.expect(key.text == null);
        try testing.expect(key.shifted_codepoint == null);
    }
}

test "parse: kitty: a named key is never given synthesized text" {
    // `Key.home` lives in the kitty private use area. Synthesizing text
    // for it would make a function key look like a printable character.
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b[57356;2u";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const key = result.event.?.key_press;

    try testing.expectEqual(Key.home, key.codepoint);
    try testing.expect(key.text == null);
    try testing.expect(key.shifted_codepoint == null);
}

test "parse: kitty: modifier shortcuts are never given synthesized text" {
    // Ctrl+a reports U+0061 plus Ctrl. It is a shortcut, not text.
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b[97;5u";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const key = result.event.?.key_press;

    try testing.expectEqual(@as(u21, 'a'), key.codepoint);
    try testing.expect(key.text == null);
    try testing.expect(key.matches('a', .{ .ctrl = true }));
}

test "parse: kitty: alt+shift+a without text reporting" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b[97:65;4u";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{
        .codepoint = 'a',
        .shifted_codepoint = 'A',
        .mods = .{ .shift = true, .alt = true },
    };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(10, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: kitty: a without text reporting" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b[97u";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{
        .codepoint = 'a',
    };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(5, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: kitty: release event" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b[97;1:3u";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{
        .codepoint = 'a',
    };
    const expected_event: Event = .{ .key_release = expected_key };

    try testing.expectEqual(9, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: single codepoint" {
    const alloc = testing.allocator_instance.allocator();
    const input = "🙂";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{
        .codepoint = 0x1F642,
        .text = input,
    };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(4, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: single codepoint with more in buffer" {
    const alloc = testing.allocator_instance.allocator();
    const input = "🙂a";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{
        .codepoint = 0x1F642,
        .text = "🙂",
    };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(4, result.n);
    try testing.expectEqualDeep(expected_event, result.event);
}

test "parse: multiple codepoint grapheme" {
    const alloc = testing.allocator_instance.allocator();
    const input = "👩‍🚀";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{
        .codepoint = Key.multicodepoint,
        .text = input,
    };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(input.len, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: multiple codepoint grapheme with more after" {
    const alloc = testing.allocator_instance.allocator();
    const input = "👩‍🚀abc";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{
        .codepoint = Key.multicodepoint,
        .text = "👩‍🚀",
    };

    try testing.expectEqual(expected_key.text.?.len, result.n);
    const actual = result.event.?.key_press;
    try testing.expectEqualStrings(expected_key.text.?, actual.text.?);
    try testing.expectEqual(expected_key.codepoint, actual.codepoint);
}

test "parse: flag emoji" {
    const alloc = testing.allocator_instance.allocator();
    const input = "🇺🇸";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{
        .codepoint = Key.multicodepoint,
        .text = input,
    };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(input.len, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: combining mark" {
    const alloc = testing.allocator_instance.allocator();
    // a with combining acute accent (NFD form)
    const input = "a\u{0301}";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{
        .codepoint = Key.multicodepoint,
        .text = input,
    };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(input.len, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: skin tone emoji" {
    const alloc = testing.allocator_instance.allocator();
    const input = "👋🏿";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{
        .codepoint = Key.multicodepoint,
        .text = input,
    };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(input.len, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: text variation selector" {
    const alloc = testing.allocator_instance.allocator();
    // Heavy black heart with text variation selector
    const input = "❤︎";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{
        .codepoint = Key.multicodepoint,
        .text = input,
    };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(input.len, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: keycap sequence" {
    const alloc = testing.allocator_instance.allocator();
    const input = "1️⃣";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{
        .codepoint = Key.multicodepoint,
        .text = input,
    };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(input.len, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse(csi): kitty multi cursor (dropped tag: consumed, no event)" {
    var buf: [1]u8 = undefined;
    {
        const input = "\x1b[>1;2;3;29;30;40;100;101 q";
        const result = parseCsi(input, &buf);
        const expected: Result = .{
            .event = null,
            .n = input.len,
        };

        try testing.expectEqual(expected.n, result.n);
        try testing.expectEqual(expected.event, result.event);
    }
    {
        const input = "\x1b[> q";
        const result = parseCsi(input, &buf);
        const expected: Result = .{
            .event = null,
            .n = input.len,
        };

        try testing.expectEqual(expected.n, result.n);
        try testing.expectEqual(expected.event, result.event);
    }
}

test "parse(csi): decrpm" {
    var buf: [1]u8 = undefined;
    {
        const input = "\x1b[?1016;1$y";
        const result = parseCsi(input, &buf);
        const expected: Result = .{
            .event = .{ .cap = .sgr_pixels },
            .n = input.len,
        };

        try testing.expectEqual(expected.n, result.n);
        try testing.expectEqual(expected.event, result.event);
    }
    {
        const input = "\x1b[?1016;0$y";
        const result = parseCsi(input, &buf);
        const expected: Result = .{
            .event = null,
            .n = input.len,
        };

        try testing.expectEqual(expected.n, result.n);
        try testing.expectEqual(expected.event, result.event);
    }
}

test "parse(csi): decrpm cap replies" {
    var buf: [1]u8 = undefined;
    const vectors = [_]struct { input: []const u8, expected: ?Event }{
        .{ .input = "\x1b[?1004;1$y", .expected = .{ .cap = .focus_events } },
        .{ .input = "\x1b[?2004;1$y", .expected = .{ .cap = .bracketed_paste } },
        .{ .input = "\x1b[?2026;1$y", .expected = .{ .cap = .sync_output } },
        .{ .input = "\x1b[?2027;1$y", .expected = .{ .cap = .unicode_core } },
        .{ .input = "\x1b[?2026;0$y", .expected = null },
        .{ .input = "\x1b[?2027;4$y", .expected = null },
    };
    for (vectors) |v| {
        const result = parseCsi(v.input, &buf);
        try testing.expectEqual(v.input.len, result.n);
        try testing.expectEqual(v.expected, result.event);
    }
}

test "parse(csi): kitty keyboard cap reply" {
    var buf: [1]u8 = undefined;
    {
        // reply to a CSI ? u query
        const input = "\x1b[?1u";
        const result = parseCsi(input, &buf);
        const expected: Result = .{
            .event = .{ .cap = .kitty_keyboard },
            .n = input.len,
        };

        try testing.expectEqual(expected.n, result.n);
        try testing.expectEqual(expected.event, result.event);
    }
    {
        // reply to a CSI > flags u push (the form caps.zig uses)
        const input = "\x1b[>1;1u";
        const result = parseCsi(input, &buf);
        const expected: Result = .{
            .event = .{ .cap = .kitty_keyboard },
            .n = input.len,
        };

        try testing.expectEqual(expected.n, result.n);
        try testing.expectEqual(expected.event, result.event);
    }
}

test "parse(csi): primary da (dropped tag: consumed, no event)" {
    var buf: [1]u8 = undefined;
    const input = "\x1b[?c";
    const result = parseCsi(input, &buf);
    const expected: Result = .{
        .event = null,
        .n = input.len,
    };

    try testing.expectEqual(expected.n, result.n);
    try testing.expectEqual(expected.event, result.event);
}

test "parse(csi): dsr (dropped tag: consumed, no event)" {
    var buf: [1]u8 = undefined;
    {
        const input = "\x1b[?997;1n";
        const result = parseCsi(input, &buf);
        const expected: Result = .{
            .event = null,
            .n = input.len,
        };

        try testing.expectEqual(expected.n, result.n);
        try testing.expectEqual(expected.event, result.event);
    }
    {
        const input = "\x1b[?997;2n";
        const result = parseCsi(input, &buf);
        const expected: Result = .{
            .event = null,
            .n = input.len,
        };

        try testing.expectEqual(expected.n, result.n);
        try testing.expectEqual(expected.event, result.event);
    }
    {
        const input = "\x1b[0n";
        const result = parseCsi(input, &buf);
        const expected: Result = .{
            .event = null,
            .n = input.len,
        };

        try testing.expectEqual(expected.n, result.n);
        try testing.expectEqual(expected.event, result.event);
    }
}

test "parse(csi): mouse" {
    var buf: [1]u8 = undefined;
    const input = "\x1b[<35;1;1m";
    const result = parseCsi(input, &buf);
    const expected: Result = .{
        .event = .{ .mouse = .{
            .col = 0,
            .row = 0,
            .button = .none,
            .type = .motion,
            .mods = .{},
        } },
        .n = input.len,
    };

    try testing.expectEqual(expected.n, result.n);
    try testing.expectEqual(expected.event, result.event);
}

test "parse(csi): mouse (negative)" {
    var buf: [1]u8 = undefined;
    const input = "\x1b[<35;-50;-100m";
    const result = parseCsi(input, &buf);
    const expected: Result = .{
        .event = .{ .mouse = .{
            .col = -51,
            .row = -101,
            .button = .none,
            .type = .motion,
            .mods = .{},
        } },
        .n = input.len,
    };

    try testing.expectEqual(expected.n, result.n);
    try testing.expectEqual(expected.event, result.event);
}

test "parse(csi): xterm mouse" {
    var buf: [1]u8 = undefined;
    const input = "\x1b[M\x20\x21\x21";
    const result = parseCsi(input, &buf);
    const expected: Result = .{
        .event = .{ .mouse = .{
            .col = 0,
            .row = 0,
            .button = .left,
            .type = .press,
            .mods = .{},
        } },
        .n = input.len,
    };

    try testing.expectEqual(expected.n, result.n);
    try testing.expectEqual(expected.event, result.event);
}

test "parse(csi): sgr mouse drag with button held" {
    var buf: [1]u8 = undefined;
    const vectors = [_]struct { input: []const u8, button: Mouse.Button }{
        // SGR 1006: button 0-2 + motion bit 32 = drag while button held
        .{ .input = "\x1b[<32;10;20M", .button = .left },
        .{ .input = "\x1b[<33;10;20M", .button = .middle },
        .{ .input = "\x1b[<34;10;20M", .button = .right },
    };
    for (vectors) |v| {
        const result = parseCsi(v.input, &buf);
        const expected: Result = .{
            .event = .{ .mouse = .{
                .col = 9,
                .row = 19,
                .button = v.button,
                .type = .drag,
                .mods = .{},
            } },
            .n = v.input.len,
        };

        try testing.expectEqual(expected.n, result.n);
        try testing.expectEqual(expected.event, result.event);
    }
}

test "parse(csi): sgr mouse drag with modifiers" {
    var buf: [1]u8 = undefined;
    // button 0 + motion 32 + shift 4 = 36
    const input = "\x1b[<36;10;20M";
    const result = parseCsi(input, &buf);
    const expected: Result = .{
        .event = .{ .mouse = .{
            .col = 9,
            .row = 19,
            .button = .left,
            .type = .drag,
            .mods = .{ .shift = true },
        } },
        .n = input.len,
    };

    try testing.expectEqual(expected.n, result.n);
    try testing.expectEqual(expected.event, result.event);
}

test "parse(csi): sgr mouse motion without button" {
    var buf: [1]u8 = undefined;
    // button 3 + motion bit 32 = motion with no button held
    const input = "\x1b[<35;10;20M";
    const result = parseCsi(input, &buf);
    const expected: Result = .{
        .event = .{ .mouse = .{
            .col = 9,
            .row = 19,
            .button = .none,
            .type = .motion,
            .mods = .{},
        } },
        .n = input.len,
    };

    try testing.expectEqual(expected.n, result.n);
    try testing.expectEqual(expected.event, result.event);
}

test "parse(csi): sgr mouse release" {
    var buf: [1]u8 = undefined;
    const input = "\x1b[<3;10;20m";
    const result = parseCsi(input, &buf);
    const expected: Result = .{
        .event = .{ .mouse = .{
            .col = 9,
            .row = 19,
            .button = .none,
            .type = .release,
            .mods = .{},
        } },
        .n = input.len,
    };

    try testing.expectEqual(expected.n, result.n);
    try testing.expectEqual(expected.event, result.event);
}

test "parse(csi): sgr 1016 pixel mouse with offsets" {
    var buf: [1]u8 = undefined;
    const vectors = [_]struct { input: []const u8, button: Mouse.Button, type: Mouse.Type, xoff: u16, yoff: u16 }{
        // SGR 1016: `;xoffset;yoffset` follow the y param
        .{ .input = "\x1b[<35;10;20;100;200M", .button = .none, .type = .motion, .xoff = 100, .yoff = 200 },
        .{ .input = "\x1b[<0;10;20;5;7M", .button = .left, .type = .press, .xoff = 5, .yoff = 7 },
        .{ .input = "\x1b[<32;10;20;1;2M", .button = .left, .type = .drag, .xoff = 1, .yoff = 2 },
    };
    for (vectors) |v| {
        const result = parseCsi(v.input, &buf);
        const expected: Result = .{
            .event = .{ .mouse = .{
                .col = 9,
                .row = 19,
                .xoffset = v.xoff,
                .yoffset = v.yoff,
                .button = v.button,
                .type = v.type,
                .mods = .{},
            } },
            .n = v.input.len,
        };

        try testing.expectEqual(expected.n, result.n);
        try testing.expectEqual(expected.event, result.event);
    }
}

test "parse(csi): xterm mouse drag and motion" {
    var buf: [1]u8 = undefined;
    {
        // X10 any-event mode: byte 32|button + 32 (0x40 '@' = left drag)
        const input = "\x1b[M@!!";
        const result = parseCsi(input, &buf);
        const expected: Result = .{
            .event = .{ .mouse = .{
                .col = 0,
                .row = 0,
                .button = .left,
                .type = .drag,
                .mods = .{},
            } },
            .n = input.len,
        };

        try testing.expectEqual(expected.n, result.n);
        try testing.expectEqual(expected.event, result.event);
    }
    {
        // byte 35 + 32 (0x43 'C' = motion, no button)
        const input = "\x1b[MC!!";
        const result = parseCsi(input, &buf);
        const expected: Result = .{
            .event = .{ .mouse = .{
                .col = 0,
                .row = 0,
                .button = .none,
                .type = .motion,
                .mods = .{},
            } },
            .n = input.len,
        };

        try testing.expectEqual(expected.n, result.n);
        try testing.expectEqual(expected.event, result.event);
    }
}

test "parse(csi): xterm mouse payload bytes below 32 (no overflow)" {
    var buf: [1]u8 = undefined;
    // payload bytes below 32 would underflow the `- 32` decode and panic
    // (fuzz regression: integer overflow); they must saturate instead
    const input = "\x1b[M\x00\x00\x00";
    const result = parseCsi(input, &buf);
    const expected: Result = .{
        .event = .{ .mouse = .{
            .col = 0,
            .row = 0,
            .button = .left,
            .type = .press,
            .mods = .{},
        } },
        .n = input.len,
    };

    try testing.expectEqual(expected.n, result.n);
    try testing.expectEqual(expected.event, result.event);
}

test "parse: disambiguate shift + space" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b[32;2u";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{
        .codepoint = ' ',
        .shifted_codepoint = ' ',
        .mods = .{ .shift = true },
        .text = " ",
    };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(7, result.n);
    try testing.expectEqualDeep(expected_event, result.event);
}

// --- notui additions: cpr divergence vectors ---

test "parse: cpr reply" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b[5;10R";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_event: Event = .{ .cpr = .{ .row = 5, .col = 10 } };

    try testing.expectEqual(7, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: cpr reply 1;1" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b[1;1R";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_event: Event = .{ .cpr = .{ .row = 1, .col = 1 } };

    try testing.expectEqual(6, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: bare csi R stays legacy f3" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b[R";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{ .codepoint = Key.f3 };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(3, result.n);
    try testing.expectEqual(expected_event, result.event);
}

// --- notui additions: ground-state grapheme vectors (zg swap) ---

test "parse: ground zwj family grapheme" {
    const alloc = testing.allocator_instance.allocator();
    const input = "👨‍🌾";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{
        .codepoint = Key.multicodepoint,
        .text = input,
    };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(input.len, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: ground combining mark e" {
    const alloc = testing.allocator_instance.allocator();
    // e with combining acute accent (NFD form)
    const input = "e\u{0301}";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{
        .codepoint = Key.multicodepoint,
        .text = input,
    };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(input.len, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: ground ascii passthrough" {
    const alloc = testing.allocator_instance.allocator();
    const input = "z";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);
    const expected_key: Key = .{
        .codepoint = 'z',
        .text = "z",
    };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(1, result.n);
    try testing.expectEqual(expected_event, result.event);
}

// --- notui additions: incomplete input vectors ---

test "parse: incomplete csi (null event, n == 0)" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b[";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);

    try testing.expect(result.event == null);
    try testing.expectEqual(@as(usize, 0), result.n);
}

test "parse: incomplete kitty seq (null event, n == 0)" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b[97;";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);

    try testing.expect(result.event == null);
    try testing.expectEqual(@as(usize, 0), result.n);
}

test "parse: apc (dropped tag: consumed, no event)" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b_kitty\x1b\\";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);

    try testing.expectEqual(input.len, result.n);
    try testing.expect(result.event == null);
}

test "parse(apc): kitty graphics query reply decodes as cap" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b_Gi=9931;OK\x1b\\";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);

    try testing.expectEqual(input.len, result.n);
    try testing.expectEqual(@as(?Event, .{ .cap = .kitty_graphics }), result.event);
}

test "parse(apc): kitty graphics reply with env suffix decodes as cap" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b_Gi=9931;OK;ENV_f=24;c=24,32\x1b\\";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);

    try testing.expectEqual(input.len, result.n);
    try testing.expectEqual(@as(?Event, .{ .cap = .kitty_graphics }), result.event);
}

test "parse(apc): non-probe APC payload is skipped harmlessly" {
    const alloc = testing.allocator_instance.allocator();
    // an image chunk APC: no i=9931 probe id → consumed, no event
    const input = "\x1b_Ga=q,t=f,s=100,v=1;AAAA\x1b\\";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);

    try testing.expectEqual(input.len, result.n);
    try testing.expect(result.event == null);
}

test "parse(apc): superstring id does not match the probe" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b_Gi=99312;OK\x1b\\";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);

    try testing.expectEqual(input.len, result.n);
    try testing.expect(result.event == null);
}

test "parse(apc): error reply does not decode as cap" {
    const alloc = testing.allocator_instance.allocator();
    const input = "\x1b_Gi=9931;ENOENT:bad\x1b\\";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);

    try testing.expectEqual(input.len, result.n);
    try testing.expect(result.event == null);
}

test "parse: incomplete apc (null event, n == 0)" {
    const alloc = testing.allocator_instance.allocator();
    // APC whose ST's ESC is the final byte: parseApc must not read past the
    // end of the input (fuzz regression: index out of bounds)
    const input = "\x1b_\x1b";
    var parser: Parser = .{};
    const result = try parser.parse(input, alloc);

    try testing.expect(result.event == null);
    try testing.expectEqual(@as(usize, 0), result.n);
}

test "fuzz: parser never panics on arbitrary input" {
    // Corpus-seeded from the conformance vectors above so the fuzzer starts
    // from known-good sequences (SGR 1006/1016 mouse, X10, OSC 52, CPR, …).
    try std.testing.fuzz(@as(void, undefined), testFuzz, .{
        .corpus = &.{
            "a",
            "\x1b",
            "\x1b[A",
            "\x1b[2~",
            "\x1b[97;1:3u",
            "\x1b[<35;10;20M",
            "\x1b[<32;10;20M",
            "\x1b[<3;10;20m",
            "\x1b[<35;10;20;100;200M",
            "\x1b[M\x20\x21\x21",
            "\x1b[M@!!",
            "\x1b]52;c;aGVsbG8=\x1b\\",
            "\x1b[5;10R",
            "\x1b[?1016;1$y",
            "\x1b[?u",
            "🙂",
            "👩‍🚀",
        },
    });
}

/// The invariant check `std.testing.fuzz` runs over the corpus below.
pub fn testFuzz(_: void, smith: *std.testing.Smith) !void {
    var buf: [64]u8 = undefined;
    const len = smith.slice(&buf);

    var parser: Parser = .{};
    const input = buf[0..len];
    const result = try parser.parse(input, testing.allocator);

    if (result.event) |ev| {
        switch (ev) {
            .paste => |text| testing.allocator.free(text),
            else => {},
        }
    }

    // Invariants: parse is a prefix consumer — it may consume nothing
    // (incomplete input) but never more than it was given, and an event
    // always implies a non-zero consumed count.
    try testing.expect(result.n <= input.len);
    if (result.event) |ev| {
        try testing.expect(result.n >= 1);
        switch (ev) {
            // per-event-kind minimal sequence lengths
            .mouse => try testing.expect(result.n >= 6),
            // A CPR is `CSI row;col R`; the shortest capability reply is the
            // four-byte kitty keyboard answer `CSI ? u`.
            .cpr => try testing.expect(result.n >= 5),
            .cap => try testing.expect(result.n >= 4),
            .focus_in, .focus_out, .key_release, .winsize, .paste => try testing.expect(result.n >= 3),
            else => {},
        }
    } else {
        // documented: incomplete input reports n == 0; unknown/consumed
        // sequences report n > 0 with no event.
    }
}

test {
    std.testing.refAllDecls(@This());
}

test "parser: malformed DECRPM consumes only its prefix without an event" {
    const cases = [_]struct { bytes: []const u8, consumed: usize }{
        .{ .bytes = "\x1b[10;y", .consumed = 6 },
        .{ .bytes = "\x1b[100;y", .consumed = 7 },
        .{ .bytes = "\x1b[y2027;1$y", .consumed = 3 },
    };
    for (cases) |case| {
        var parser: Parser = .{};
        const result = try parser.parse(case.bytes, null);
        try testing.expect(result.event == null);
        try testing.expectEqual(case.consumed, result.n);
        if (result.n < case.bytes.len) {
            const tail = try parser.parse(case.bytes[result.n..], null);
            try testing.expectEqual(@as(u21, '2'), tail.event.?.key_press.codepoint);
            try testing.expectEqual(@as(usize, 1), tail.n);
        }
    }
}

test "parser: DECRPM reply parameters are bounded by the '?' prefix and '$' trailer" {
    const cases = [_]struct {
        bytes: []const u8,
        event: ?Event,
        consumed: usize,
        tail: ?u21,
    }{
        // A valid reply stops at its `$ y` trailer and leaves the next key.
        .{ .bytes = "\x1b[?2027;1$ya", .event = .{ .cap = .unicode_core }, .consumed = 11, .tail = 'a' },
        // No `$` trailer, so the trailing `2` is not read as `Pm`.
        .{ .bytes = "\x1b[?2027;2yx", .event = null, .consumed = 10, .tail = 'x' },
        // No `?` private prefix, so the digits are not reply parameters.
        .{ .bytes = "\x1b[2027;2$y", .event = null, .consumed = 10, .tail = null },
        // Neither parameter between the prefix and the trailer.
        .{ .bytes = "\x1b[?$ya", .event = null, .consumed = 5, .tail = 'a' },
    };
    for (cases) |case| {
        var parser: Parser = .{};
        const result = try parser.parse(case.bytes, null);
        try testing.expectEqual(case.consumed, result.n);
        try testing.expectEqual(case.event, result.event);
        if (case.tail) |cp| {
            const rest = case.bytes[case.consumed..];
            const tail = try parser.parse(rest, null);
            try testing.expectEqual(rest.len, tail.n);
            const tail_event = tail.event orelse return error.TailKeyMissing;
            try testing.expect(std.meta.activeTag(tail_event) == .key_press);
            try testing.expectEqual(cp, tail_event.key_press.codepoint);
        } else {
            // No tail case: the sequence is the whole input, so `consumed`
            // states its true length.
            try testing.expectEqual(case.bytes.len, result.n);
        }
    }
}
