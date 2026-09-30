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

/// The return type of our parse method. Contains an Event and the number of
/// bytes read from the buffer.
pub const Result = struct {
    event: ?Event,
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

// the state of the parser
const State = enum {
    ground,
    escape,
    csi,
    osc,
    dcs,
    sos,
    pm,
    apc,
    ss2,
    ss3,
};

// a buffer to temporarily store text in. We need this to encode
// text-as-codepoints
buf: [128]u8 = undefined,

/// Parse the first event from the input buffer. If a completion event is not
/// present, Result.event will be null and Result.n will be 0
///
/// If an unknown event is found, Result.event will be null and Result.n will be
/// greater than 0
pub fn parse(self: *Parser, input: []const u8, paste_allocator: ?std.mem.Allocator) !Result {
    std.debug.assert(input.len > 0);

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

/// Parse ground state
inline fn parseGround(input: []const u8) !Result {
    std.debug.assert(input.len > 0);

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
        0x1B => escape: {
            std.debug.assert(input.len == 1); // parseGround expects len == 1 with 0x1b
            break :escape .{
                .codepoint = Key.escape,
            };
        },
        0x7F => .{ .codepoint = Key.backspace },
        else => blk: {
            // uucode→zg swap: validate the first codepoint with std.unicode
            // (Utf8View preserves the InvalidUTF8 behavior) and get the first
            // grapheme's byte span from the width seam (zg Graphemes lives
            // only behind src/width.zig).
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
    // capability surface and decodes as an Event.cap. All other APC
    // payloads (image chunks, transmit-data) are consumed without an
    // event (dropped tag: not in §5).
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
/// params contain the probe id as a whole comma-delimited field and the
/// payload begins with "OK" (optionally followed by ";ENV_…"). Mirrors
/// zigzag parseKittyGraphicsProbeResponse.
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
            // the palette index is validated but not carried in the §5 Report
            const ps_idx = std.fmt.parseUnsigned(
                u8,
                input[semicolon_idx + 1 .. color_idx_delim],
                10,
            ) catch return null_event;
            _ = ps_idx;
            const color_spec = if (bel_terminated)
                input[color_idx_delim + 1 .. sequence.len - 1]
            else
                input[color_idx_delim + 1 .. sequence.len - 2];

            const color = try Color.rgbFromSpec(color_spec);
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
            const color_spec = if (bel_terminated)
                input[semicolon_idx + 1 .. sequence.len - 1]
            else
                input[semicolon_idx + 1 .. sequence.len - 2];

            const color = try Color.rgbFromSpec(color_spec);
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
            if (input[semicolon_idx + 1] != 'c') return null_event;
            const payload = if (bel_terminated)
                input[semicolon_idx + 3 .. sequence.len - 1]
            else
                input[semicolon_idx + 3 .. sequence.len - 2];
            const decoder = std.base64.standard.Decoder;
            const text = try paste_allocator.?.alloc(u8, try decoder.calcSizeForSlice(payload));
            errdefer paste_allocator.?.free(text);
            try decoder.decode(text, payload);
            log.debug("decoded paste: {s}", .{text});
            return .{
                .event = .{ .paste = text },
                .n = sequence.len,
            };
        },
        else => return null_event,
    }
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
                    // event: the pasted bytes arrive as ordinary ground-state
                    // keys (dropped tags per §5)
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
            // Primary DA (CSI ? Pm c) — consumed without an event: caps.zig
            // splits the DA1 reply params itself (dropped tag: not in §5)
            return null_event;
        },
        'n' => {
            // Device Status Report
            // CSI Ps n / CSI ? Ps n — the §5 surface only decodes CPR
            // (final 'R'); other DSR replies (e.g. color scheme 997) are
            // consumed without an event (dropped tag)
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
                // We check if we have *only* shift, no text, and a printable character. This can
                // happen when we have disambiguate on and a key is pressed and encoded as CSI u,
                // for example shift + space can produce CSI 32 ; 2 u
                const mod_test: Key.Modifiers = .{
                    .shift = true,
                    .caps_lock = key.mods.caps_lock,
                    .num_lock = key.mods.num_lock,
                };
                if (key.text == null and
                    key.mods.eql(mod_test) and
                    key.codepoint <= std.math.maxInt(u8) and
                    std.ascii.isPrint(@intCast(key.codepoint)))
                {
                    // Encode the codepoint as upper
                    const upper = std.ascii.toUpper(@intCast(key.codepoint));
                    const n = std.unicode.utf8Encode(upper, text_buf) catch unreachable;
                    key.text = text_buf[0..n];
                    key.shifted_codepoint = upper;
                }
            }

            const event: Event = if (is_release)
                .{ .key_release = key }
            else
                .{ .key_press = key };

            return .{ .event = event, .n = sequence.len };
        },
        'y' => {
            // DECRPM (CSI ? Ps ; Pm $ y)
            const delim_idx = std.mem.indexOfScalarPos(u8, input, 3, ';') orelse return null_event;
            const ps = std.fmt.parseUnsigned(u16, input[3..delim_idx], 10) catch return null_event;
            const pm = std.fmt.parseUnsigned(u8, input[delim_idx + 1 .. sequence.len - 2], 10) catch return null_event;
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
                // Color scheme reporting (dropped tag: not in §5)
                2031 => return null_event,
                else => return null_event,
            }
        },
        'q' => {
            // kitty multi cursor cap (CSI > 1;2;3;29;30;40;100;101 q) —
            // consumed without an event (dropped tag: not in §5)
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

    // mouse leave events are consumed without an event (dropped tag per §5)
    if (button_mask & mouse_bits.leave > 0)
        return .{ .event = null, .n = if (xterm) 6 else input.len };

    const button: Mouse.Button = @enumFromInt(button_mask & mouse_bits.buttons);
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
            "🙂",
            "👩‍🚀",
        },
    });
}

/// Public so other modules (e.g. a standalone fuzz driver) can reuse it.
pub fn testFuzz(_: void, smith: *std.testing.Smith) !void {
    var buf: [64]u8 = undefined;
    const len = smith.slice(&buf);
    // parse asserts non-empty input; the empty string is the runner's
    // default smoke input and must be skipped.
    if (len == 0) return;

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
            .cpr, .cap => try testing.expect(result.n >= 5),
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
