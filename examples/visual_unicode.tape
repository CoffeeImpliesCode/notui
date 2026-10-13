# visual_unicode.tape — ./zig-out/bin/example-prompt under VHS 0.11.0
# (ttyd 1.7.7, ffmpeg 9, DejaVu Sans Mono plus the devenv Fontconfig CJK
# and emoji fallback). notui never enters the alternate screen, so the
# printf banner printed before the app starts is still in the transcript
# in every later frame — that is what makes the baseline/app pair below a
# comparison of the same bytes instead of two unrelated pictures.
#
# What the app does (examples/prompt.zig):
#   band       one row painted as "prompt > " + the echoed line (:33, :120)
#   clipping   Buffer.draw drops whatever does not fit the region width, so
#              an over-wide line is cut and never wraps (:118-124); a wide
#              glyph that would cross the right edge drops with the rest
#              (src/buffer.zig:134-155)
#   Enter      the line is cut into region-width chunks and each chunk is
#              queued as a `.line` row ABOVE the band in scrollback
#              (:131-139)
#   Backspace  pops exactly one UTF-8 codepoint, so the combining acute in
#              "e" + U+0301 goes on its own and the base "e" stays (:171-181)
#   ctrl+c     clears the line, the app keeps running (:81-83)
#   ctrl+d     always quits, whatever the line holds (:84-85)
#
# What VHS 0.11.0 does (pinned parser, not folklore):
#   Backspace <count>   repeats the key: parser/parser.go parseKeypress
#                       hands the count to parseRepeat and command.go
#                       ExecuteKey loops over it. `vhs record` writes the
#                       same "Backspace 40" form for a repeated keypress.
#   Type "..."          types rune by rune (command.go ExecuteType), so each
#                       codepoint of a decomposed grapheme arrives as its own
#                       key event — which is what the app appends. It types
#                       the argument's runes LITERALLY: a backslash inside a
#                       double-quoted argument is a backslash, not an escape.
#   ctrl chords are LOWERCASE. VHS emits Ctrl+Shift+<key> for an uppercase
#                       letter, and the terminal frontend only folds
#                       ctrl+<letter> into a control byte when shift is NOT
#                       held, so "Ctrl+C" would reach the app as nothing.
#   Wait+Line /re/      matches a regex against the CURRENT CURSOR ROW
#                       (CurrentLine, cursorY + viewportY). The region parks
#                       the cursor on its LAST live band row, so that row IS
#                       the prompt band — and it keeps reading it after the
#                       transcript has scrolled past the top of the viewport.
#   a positive gate can pass BEFORE the canvas has painted it: Wait+Line
#                       matches xterm's buffer contents while Screenshot
#                       reads the painted canvas. Every gate immediately
#                       followed by a Screenshot therefore settles 500ms
#                       first — long enough for the app's 100ms tick and a
#                       xterm paint — or the frame catches the previous one.
#   Wait+Screen /re/    matches a regex against the whole Buffer, whose
#                       getLine(i) counts from index 0 WITHOUT the viewportY
#                       offset. Once the recipe has scrolled, the rows it
#                       reads at the top are stale lines no longer on screen,
#                       so a positive Screen gate silently stops covering the
#                       session; right after launch its last value can still
#                       be the wrapped setup command line. Every gate below is
#                       therefore Wait+Line on a short prefix of the parked
#                       band row.
#
# Everything a positive regex cannot witness — a cleared line, a popped
# combining mark, deleted cells, scrolled history, the clipped tail — gets a
# bounded settle instead: no text can appear to prove text is GONE. Waiting on
# a deleted tail or an offscreen history row would burn the 15s Wait timeout
# and take the whole tape, all ten PNGs included, down with it.
#
# The native baseline U0..U5 is printed by bash printf with EXPLICIT \ooo
# octal escapes, so no Unicode passes through bash's readline on the way to
# the terminal and the bytes are pinned by the format string itself:
#   \347\225\214      U+754C (CJK)         = E7 95 8C
#   \145\314\201      U+0065 + U+0301      = 65 CC 81  (decomposed e + acute)
#   \342\200\215      U+200D ZWJ          = E2 80 8D
#   \360\237\221\251  U+1F469 woman       = F0 9F 91 A9
#   \360\237\222\273  U+1F4BB laptop      = F0 9F 92 BB
# U5 spells the exact string the app is asked to echo next, same escapes in
# the same order, so unicode-01 and unicode-02 show one byte sequence twice —
# once through the terminal's own font stack, once through notui's grapheme
# walker. The app still receives the real Unicode through Type; only the
# shell side is escaped.
#
# No column count is asserted anywhere in this tape. VHS calls `term.fit()`,
# so the grid is whatever DejaVu Sans Mono at 20px measures inside the
# viewport minus the padding. The clip fixture is therefore built to overflow
# under any plausible fit, and every expectation is visual: a row that runs to
# the right edge, blanks to the right of a shortened row, contiguous history.
Output zig-out/visual/stress/unicode.gif

Set Width 1200
Set Height 340
Set FontSize 20
Set FontFamily "DejaVu Sans Mono"
Set Padding 20
Set TypingSpeed 10ms
Set CursorBlink false
Set Shell "bash"

# ── launch + native font baseline ──────────────────────────────────────
# U0..U5 come from the shell with no notui in the process: they are what
# DejaVu Sans Mono and the Fontconfig fallbacks draw on their own. U5 is
# the exact string the app is asked to echo next, so unicode-01 and
# unicode-02 show the same bytes twice — once through the terminal, once
# through notui's own grapheme walker.
#
# ED3 + ED2 first (see the header): the setup below is one long command that
# readline has wrapped over several rows, and that stale wrapped text would
# otherwise still be the transcript sitting under the baseline. Both are bash
# builtin printf — not notui. ED3 wipes the saved lines of THIS capture
# session only, since every VHS run gets its own ttyd. The banner still
# follows the app for the whole transcript: notui never enters the
# alternate screen.
Hide
Type "export PS1=''; "
Type "printf '\033[3J\033[2J\033[H'; "
Type "printf 'U0 NATIVE-BASELINE: printf output, no notui running\n'; "
Type "printf 'U1 ascii: hello notui world 0123456789\n'; "
Type "printf 'U2 cjk: \347\225\214 \347\225\214\347\225\214 wide glyphs\n'; "
Type "printf 'U3 combining: caf\145\314\201 decomposed e+U+0301 acute\n'; "
Type "printf 'U4 zwj-emoji: \360\237\221\251\342\200\215\360\237\222\273 woman-technologist U+1F469 ZWJ U+1F4BB\n'; "
Type "printf 'U5 mixed: ascii \347\225\214 caf\145\314\201 \360\237\221\251\342\200\215\360\237\222\273 tail\n'; "
Type "./zig-out/bin/example-prompt && printf 'PROMPT_STRESS_EXIT_OK'"
Enter
Show
# Line, not Screen: "prompt >" is the band itself, and the band is the row
# the region parks the cursor on. The shell has handed the terminal to the
# app by now, so the parked row is the app's band and never the wrapped
# setup command line. Every buffer line is right-trimmed, so the band reads
# "prompt >" with no trailing space to sit inside the regex.
Wait+Line /prompt >/
Sleep 500ms
Screenshot zig-out/visual/stress/unicode-01-native-baseline.png
Sleep 500ms

# ── the app echoes the same unicode string ────────────────────────────
# Gate on the band row's own prefix. Line reads the parked cursor row, so
# the U5 banner line — a different row — can never satisfy this; the
# "prompt > " prefix pins the match to the app's echo all the same.
Type "U5 mixed: ascii 界 café 👩‍💻 tail"
Wait+Line /prompt > U5 mixed/
Sleep 500ms
Screenshot zig-out/visual/stress/unicode-02-app-unicode-echo.png
Sleep 500ms
# Compare against unicode-01: the CJK glyphs, the accented cluster and the
# ZWJ sequence must land on the same cells in both frames, and the band row
# must be one row. The app selects cell clusters from terminal DEC 2027 support
# (src/width.zig firstCellLen). A legacy terminal advances four cells for 👩‍💻;
# a grapheme terminal advances two. In either case the text after it must start
# at the terminal's actual next column, without losing the tail at the margin.

# ── ctrl+c clears the line, the app stays up ───────────────────────────
# Lowercase chord: uppercase "Ctrl+C" would be Ctrl+Shift+C and reach the
# app as nothing, leaving the line full and the frame meaningless.
# A cleared line is a deletion: nothing new can appear to prove it is gone.
# 500ms covers the app's 100ms tick (tick_ms, prompt.zig:39) several times.
Ctrl+c
Sleep 500ms
Screenshot zig-out/visual/stress/unicode-03-ctrl-c-cleared.png
Sleep 500ms

# ── one Backspace over a combining mark ───────────────────────────────
# The accented final letter is typed as its own Type command, so "e" and
# U+0301 are two key events and the line really ends in a combining mark.
Type "U6 backspace: caf"
Type "é"
Wait+Line /prompt > U6 backspace: caf/
Sleep 500ms
Screenshot zig-out/visual/stress/unicode-04-backspace-combining-before.png
Sleep 500ms

# ONE Backspace pops ONE codepoint (prompt.zig:174-181): U+0301 goes on its
# own and the base "e" stays, so the band loses the accent and keeps the
# letter — "cafe", not "caf", and not a vanished base letter. The change is a
# glyph that DISAPPEARS, so no positive regex can witness it; settle instead.
Backspace
Sleep 500ms
Screenshot zig-out/visual/stress/unicode-05-backspace-combining-after.png
Sleep 500ms

Ctrl+c
Sleep 500ms

# ── over-long input clipped at the right edge ──────────────────────────
# 19 + 3x62 + 32 = 237 codepoints: far wider than any column count a 20px
# monospace fit can produce inside 1200px minus the padding, so the row MUST
# clip whatever term.fit() decided. Only the head is gated, and it sits at
# the LEFT of the same single band row Line reads, so the clip never hides
# the gate: the tail marker is exactly the part that must NOT be on screen,
# and waiting for it would burn the 15s Wait timeout and take the whole
# tape, all ten PNGs included, down with it.
Type "CLIP-HEAD-OK 界界 é "
Type "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
Type "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
Type "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
Type "CLIP-TAIL-BEYOND-THE-REGION-EDGE"
Wait+Line /prompt > CLIP-HEAD-OK/
Sleep 500ms
Screenshot zig-out/visual/stress/unicode-06-clip-right-edge.png
Sleep 500ms
# Expect: the head marker at the left, then as much filler as reaches the
# last column, and nothing beyond it. One row only — the band is cut, never
# wrapped, so there is no second row and the band does not drift downward.

# ── delete the whole clipped line ──────────────────────────────────────
# `Backspace 218` pops the three 62-codepoint filler blocks and the
# 32-codepoint tail marker, leaving only the 19-codepoint head — short enough
# to end inside the region under any fit(). The frame is the check that the
# band repaints every cell the clipped render had painted: the row must stop
# right after the head and be blank to the right edge, with no leftover
# glyphs. A deletion again, so a bounded settle again.
Backspace 218
Sleep 500ms
Screenshot zig-out/visual/stress/unicode-07-backspace-stale-tail.png
Sleep 500ms

# ── Enter: one submission becomes several scrollback rows ──────────────
# pushLine cuts the text at the region width and queues each chunk as a
# `.line` row above the band, so an over-wide submission occupies several
# rows and the band's anchor does not drift — that chunking is the entire
# reason prompt.zig:131-139 exists. The marker is new text, but the session
# now carries more rows than the viewport holds, so the buffer-text window no
# longer covers it: settle, do not wait.
Type "WRAP-CHECK 界界界 "
Type "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
Type "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
Type "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
Type "WRAP-CHECK-END"
Enter
Sleep 800ms
Screenshot zig-out/visual/stress/unicode-08-wrapped-history.png
Sleep 500ms
# Expect: the submission spread over consecutive full-width rows above the
# band, cut at the region width rather than at the terminal's own wrap, and
# the band still the last row of the screen.

# ── twelve more rows: the history overflows the viewport ───────────────
# Twelve single-row submissions, numbered 01..12 so every row is
# identifiable and no two rows carry the same text. Row 12 is the end marker:
# it is the newest row, so it sits directly above the band and is in frame
# whatever height the viewport turned out to be, while the earliest rows have
# scrolled out of it — which is the invariant under test.
Type "OVERFLOW-ROW-01-OF-12"
Enter
Sleep 200ms
Type "OVERFLOW-ROW-02-OF-12"
Enter
Sleep 200ms
Type "OVERFLOW-ROW-03-OF-12"
Enter
Sleep 200ms
Type "OVERFLOW-ROW-04-OF-12"
Enter
Sleep 200ms
Type "OVERFLOW-ROW-05-OF-12"
Enter
Sleep 200ms
Type "OVERFLOW-ROW-06-OF-12"
Enter
Sleep 200ms
Type "OVERFLOW-ROW-07-OF-12"
Enter
Sleep 200ms
Type "OVERFLOW-ROW-08-OF-12"
Enter
Sleep 200ms
Type "OVERFLOW-ROW-09-OF-12"
Enter
Sleep 200ms
Type "OVERFLOW-ROW-10-OF-12"
Enter
Sleep 200ms
Type "OVERFLOW-ROW-11-OF-12"
Enter
Sleep 200ms
Type "OVERFLOW-ROW-12-OF-12"
Enter
Sleep 800ms
Screenshot zig-out/visual/stress/unicode-09-overflow-scrolled.png
Sleep 500ms
# Expect: the tail of the numbered rows ending at 12 directly above the band,
# the band intact at the bottom, and no row repeated, mangled or half-painted.

# Clean exit: ctrl+d (lowercase chord), the app restores the terminal and
# region.exit parks the cursor. The `&&` only reaches the printf when the
# app exited 0, so the marker landing on the parked row IS the exit-status
# proof. Omit the printf newline so it stays on that row, and Line reads it
# even after the 12 history rows scrolled the transcript.
Ctrl+d
Wait+Line /PROMPT_STRESS_EXIT_OK/
Sleep 500ms
Screenshot zig-out/visual/stress/unicode-10-exit.png
Sleep 500ms
