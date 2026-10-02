# visual_editor.tape — skript REPL editor: completion popup, Tab accept,
# Esc, codepoint-granular Unicode editing, mid-line insert, line-end
# chords, eval and history. Real TTY (examples/skript_repl.zig), recorded
# by VHS 0.11 through ttyd.
#
# Expected scenes
#   idle band    "skript> " plus the status hint "Enter: eval · ↑/↓:
#                history · ^C: clear (quit while eval) · ^D/q: quit"
#   popup        candidate rows under the input line, at most 8 rows,
#                the selected row reverse-video, anchored at the first
#                column of the token being completed. Candidates are the
#                root_ns bindings that start with the token under the
#                cursor plus the special forms, sorted bytewise:
#                  "ma" -> mag map map-get map-has? map-keys map-set!
#                           map-size map-vals map2 max  (10 candidates)
#                  "se" -> self send set!                 (3 candidates)
#   highlight    "v1" green, integers yellow, "let" blue
#   answer       " ⇒ 42 (i64)" (bare integer literals are i64), captured
#                on the answer checkpoint and never gated
#   cursor       a reverse-video block; all cursor movement is CODEPOINT
#                granular, never grapheme granular
#
# VHS 0.11 rules this tape obeys
#   * ctrl chords are lowercase. VHS sends Ctrl+Shift+<key> for an
#     uppercase letter, and the terminal frontend only turns ctrl+<letter>
#     into a control byte when shift is NOT held, so "Ctrl+U" would reach
#     the app as nothing at all.
#   * Escape, Delete, Backspace, Left, Right, Up, Down, Tab and Enter are
#     keypress commands; Home and End are not (they fail to parse), so the
#     line-end checkpoints press the app's Ctrl+A / Ctrl+E chords, which
#     take the same code path as Home / End.
#   * a literal " in a Type argument is written with single quotes. The
#     lexer does not treat \" as an escape inside a double-quoted
#     argument; it would type a backslash and then a quote.
#   * every positive gate is Wait+Line on the cursor row, and the cursor
#     row IS the status row: notui parks the cursor on the last band row,
#     which is where drawBand puts the idle hint, "multiline: Enter to
#     continue" or "done in {d}ms" — below the popup, above nothing.
#     Wait+Screen appears nowhere in this tape: VHS 0.11's Buffer walks the
#     terminal buffer from row 0 WITHOUT the viewport offset, so once the
#     session has scrolled it reads stale scrollback (the wrapped launcher
#     line) instead of the live band. CurrentLine() is the only reader that
#     adds viewportY.
#   * so a gate can only witness a STATUS change: the idle hint arriving at
#     launch, "done in {d}ms" replacing it after an eval, and that status
#     giving way to the idle hint again on the next key. The input row, the
#     popup rows and the answer rows all sit ABOVE the status row, so every
#     step whose evidence lives there — typed text, popup open / scroll /
#     accept, Esc, candidate selection, mid-line insert, backspace, chords
#     — settles with a bounded Sleep instead. The app repaints at most every
#     100 ms: 300 ms after a key step, 500 ms after typed text or a frame
#     under inspection covers that tick several times over.
#   * a settled frame is never re-taken, retried or filtered. A popup that
#     failed to open, redraw damage in the input row and a wrong or erroring
#     answer are all captured as they stand — those frames are exactly what
#     the checkpoint is for, and a failed Wait would abort the run and lose
#     every later PNG with it.
#   * the launcher prints the exit marker with NO newline. Region.exit
#     parks with "\r\n\r" below the band, so the shell resumes at column 0
#     of a fresh row and, with nothing printed after it, the cursor stays ON
#     the marker row — the row Wait+Line reads.
Output zig-out/visual/stress/editor.gif

Set Width 1200
Set Height 480
Set FontSize 20
Set FontFamily "DejaVu Sans Mono"
Set Padding 20
Set TypingSpeed 10ms
Set CursorBlink false
Set Shell "bash"

# ── launch ────────────────────────────────────────────────────────────
# The scrollback marker is printed before notui starts and must still be
# on screen at the end: notui never enters the alternate screen. The
# launch gate is the idle hint: it is the first thing the app paints, and
# it is the first thing that lands on the cursor row.
Hide
Type "export PS1=''; "
Type "printf '\033[H\033[2JSCROLLBACK BEFORE NOTUI\n'; "
Type "./zig-out/bin/example-skript-repl && "
Type "printf 'SKRIPT_EDITOR_EXIT_OK'"
Enter
Show
Wait+Line /Enter: eval/
Sleep 500ms
Screenshot zig-out/visual/stress/editor-01-idle-start.png
Sleep 500ms

# ── completion popup ──────────────────────────────────────────────────
# "ma" -> 10 candidates in an 8-row window, first row selected. The
# candidate rows live above the status row, so the popup opening is not
# gated: the frame either grew to ten rows or it did not.
Type "ma"
Sleep 500ms
Screenshot zig-out/visual/stress/editor-02-popup-open.png
Sleep 500ms

# Down x1: the highlight moves to "map"; the window still shows rows 0-7.
Down
Sleep 300ms
Screenshot zig-out/visual/stress/editor-03-popup-down1.png
Sleep 500ms

# Down x7: selected = 8 ("map2"), so the window scrolls down to rows 1-8
# and "mag" is no longer the top row.
Down
Down
Down
Down
Down
Down
Down
Sleep 300ms
Screenshot zig-out/visual/stress/editor-04-popup-scrolled.png
Sleep 500ms

# Down x1: selected = 9 ("max") and the window is rows 2-9, so "max"
# should show up for the first time. That evidence is a popup row, above
# the cursor row, so the frame is captured on a bounded settle instead.
Down
Sleep 500ms
Screenshot zig-out/visual/stress/editor-05-popup-max.png
Sleep 500ms

# Up x2: selected = 7, the window scrolls back to rows 0-7 and "mag"
# returns to the top row.
Up
Up
Sleep 300ms
Screenshot zig-out/visual/stress/editor-06-popup-up7.png
Sleep 500ms

# Tab accepts the highlighted candidate: "ma" becomes "map-vals", the
# popup collapses and the band is 2 rows again. The accepted text sits on
# the input row above the status row, so it is captured, not gated.
Tab
Sleep 500ms
Screenshot zig-out/visual/stress/editor-07-popup-accepted.png
Sleep 500ms

# ── Esc, separate from Tab ───────────────────────────────────────────
# ^U kills to the start of the line and the cursor sits at the end, so
# the line is empty again.
Ctrl+u
Sleep 300ms

# "se" -> self send set!, the first row selected — a settle for the same
# reason as "ma" above: the evidence is a popup row, not the status row.
Type "se"
Sleep 500ms
Screenshot zig-out/visual/stress/editor-08-esc-pending.png
Sleep 500ms

# SOURCE PREDICTION, not yet confirmed by a capture: Escape dismisses the
# popup, but the recompute that runs after every idle keypress is gated on
# the "accepted" flag, which only Tab sets. The very same token "se" is
# therefore re-filtered and the popup reopens with the first row selected,
# so editor-09 should look like editor-08. A 2-row band here would mean
# Escape won instead.
Escape
Sleep 300ms
Screenshot zig-out/visual/stress/editor-09-esc-after.png
Sleep 500ms

# "se3" matches nothing, and a zero-match token does dismiss the popup:
# the band returns to 2 rows and the idle hint is back on the status row.
# The status row reads the same before and after, so it gates nothing
# here; the typed token is on the input row and is captured on a settle.
Type "3"
Sleep 500ms
Screenshot zig-out/visual/stress/editor-10-esc-token-gone.png
Sleep 500ms

# ── Unicode: codepoint-granular editing ──────────────────────────────
# The line is 9 bytes and 6 columns:
#   22 65 CC 81 E6 BC A2 78 22
#    "  e  U+0301  U+6F22   x  "
# U+0301 COMBINING ACUTE ACCENT is its own Type command so it arrives as
# one key event instead of riding along with the base "e".
# The band is already 2 rows (the token at the cursor is the closing
# quote, so nothing completes), so the status row does not change and
# cannot gate this: bounded settle, frame captured as it stands.
Ctrl+u
Sleep 300ms
Type '"'
Type "e"
Type "́"
Type "漢"
Type "x"
Type '"'
Sleep 500ms
Screenshot zig-out/visual/stress/editor-11-unicode-string.png
Sleep 500ms

# Left onto the closing quote, then forward Delete takes the quote AT the
# cursor. The literal is left unterminated, so the whole rest of the line
# is painted as a string.
Left
Sleep 300ms
Delete
Sleep 300ms
Screenshot zig-out/visual/stress/editor-12-delete-forward.png
Sleep 500ms

# Left x3 walks three codepoints back: before "x", before U+6F22, before
# U+0301. U+0301 is a codepoint of its own, so the block stops ON the
# combining mark (byte 2), not on the base "e" — there is no grapheme
# handling anywhere in the cursor helpers.
Left
Left
Left
Sleep 300ms
Screenshot zig-out/visual/stress/editor-13-cursor-grapheme.png
Sleep 500ms

# Right steps over U+0301 to the start of U+6F22, then Backspace removes
# the codepoint BEFORE the cursor — U+0301 goes, not the base "e". The
# line is now "e<HAN>x" with the cursor in front of the CJK glyph.
Right
Sleep 300ms
Backspace
Sleep 300ms
Screenshot zig-out/visual/stress/editor-14-backspace-codepoint.png
Sleep 500ms

# ^C clears the WHOLE line. ^U would not: it only kills to the start, and
# the cursor is at byte 2, so the suffix would survive.
Ctrl+c
Sleep 300ms
Screenshot zig-out/visual/stress/editor-15-line-cleared.png
Sleep 500ms

# ── mid-line insert, line-end chords, eval, history ───────────────────
# The closing paren skips over the auto-inserted one, so the line ends up
# exactly "(+ 20 22)" — 9 bytes, 9 columns. That is a visual expectation
# on the input row, which is above the status row, so the frame is
# captured on a bounded settle and read by eye.
Type "(+ 20 22)"
Sleep 500ms
Screenshot zig-out/visual/stress/editor-16-expression.png
Sleep 500ms

# Left x4 steps the cursor back four codepoints — over ")" and both digits
# of "22" — landing it at byte 5, immediately after the first operand, so
# the reverse-video block sits on the space. The digit below therefore
# lands INSIDE the number and the line becomes "(+ 201 22)". The band stays
# 2 rows: a numeric token never completes, so no popup opens.
# This is the frame under inspection for redraw damage: the digit lands
# inside the number, so the input row must read "(+ 201 22)". It is
# deliberately NOT gated — a wait on that exact string would take the
# whole run down, every later PNG included, if the row paints wrong.
Left
Left
Left
Left
Sleep 300ms
Type "1"
Sleep 500ms
Screenshot zig-out/visual/stress/editor-16b-midline-insert.png
Sleep 500ms

# Backspace removes exactly the codepoint before the cursor, the "1", and
# the line is "(+ 20 22)" again. Not gated either: that is what to read
# off the frame, and a wrong paint is the thing to capture, not a reason
# to abort the checkpoints that follow.
Backspace
Sleep 500ms
Screenshot zig-out/visual/stress/editor-16c-backspace-undo.png
Sleep 500ms

# Ctrl+A is the line-start chord: the block moves to column 0 OF THE INPUT
# ROW, which is absolute column 8, immediately after the 8-column
# "skript> " prompt. (VHS 0.11 cannot send a Home key; the app maps both
# to cursor = 0.)
Ctrl+a
Sleep 300ms
Screenshot zig-out/visual/stress/editor-17-home-cursor.png
Sleep 500ms

# Ctrl+E is the matching line-end chord: the block returns past the
# closing paren.
Ctrl+e
Sleep 300ms
Screenshot zig-out/visual/stress/editor-18-end-cursor.png
Sleep 500ms

# Enter submits: the query and " ⇒ 42 (i64)" are appended above the band
# and the status becomes "done in {d}ms". The gate is that status text —
# only the worker's published result sets it, and the next key clears it —
# never the literal 42: an "Eval error:" answer is a frame this checkpoint
# exists to capture, while a wait on "42" would abort the tape instead.
# The answer row sits above the status row and is read off the PNG by eye.
Enter
Wait+Line /done in/
Sleep 500ms
Screenshot zig-out/visual/stress/editor-19-answer.png
Sleep 500ms

# Up recalls the one history entry. The cursor lands after ")", a
# completion delimiter, so the token under it is empty and no popup opens.
# Any key clears "done in {d}ms", so the idle hint coming back on the
# status row is a real gate: it can only happen after the recall landed.
Up
Wait+Line /Enter: eval/
Sleep 500ms
Screenshot zig-out/visual/stress/editor-20-history-recall.png
Sleep 500ms

# Ctrl+d — lower case: VHS sends Ctrl+Shift+<key> for an upper-case letter
# and the terminal frontend only turns ctrl+<letter> into a control byte
# when shift is NOT held. It quits even with a non-empty line, and the
# shell then prints the exit marker on the row it resumes. A real gate: if
# the app never exits, this wait times out and the tape fails rather than
# passing a session that did not shut down.
Ctrl+d
Wait+Line /SKRIPT_EDITOR_EXIT_OK/
Sleep 500ms
Screenshot zig-out/visual/stress/editor-21-exit.png
Sleep 500ms
