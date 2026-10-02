# visual_repl_multiline.tape — skript REPL multi-line continuation, real
# TTY, same binary as examples/visual_editor.tape. Recorded by VHS 0.11
# through ttyd.
#
# Expected scenes
#   idle band     "skript> " plus the status hint "Enter: eval · ↑/↓:
#                 history · ^C: clear (quit while eval) · ^D/q: quit"
#   continuation  row 0 becomes "    · " and the status row becomes
#                 "multiline: Enter to continue"
#   band          only the ACTIVE (last) line is drawn, so the highlight
#                 colours are visible on the committed lines after the
#                 eval: "let" blue, "v1" green, 20 / 22 / 18 yellow
#   answer        " ⇒ 60 (i64)", captured on the answer checkpoint and
#                 never gated
#
# The buffer that gets submitted is
#     (let ((tag "v1") (n (+ 20 22)))
#     (+ n 18))
# which reads as (let ((tag "v1") (n (+ 20 22))) (+ n 18)): n = 42, the
# body (+ n 18) = 60, and let answers with its body's value. Bare integer
# literals are i64, and `tag` is bound but never read, so the answer stays
# a plain integer.
#
# Paren depth after each step — isComplete() lex-walks the buffer and
# submits only once the depth is back to 0, otherwise it appends a newline
# and keeps reading:
#   typed chunk 1   0   the typed text PLUS the auto-closer still sitting
#                       behind the cursor: "(let ((tag "v1") (n (+ 20 22))))"
#                       is 5 openers and 5 closers, so Enter here would
#                       submit instead of continuing — hence the Ctrl+k
#   Ctrl+k          1   kills to end, dropping that trailing auto-closer so
#                       only the outer let is left open
#   Enter           1   unbalanced -> '\n' appended, continuation
#   typed chunk 2   1   "(+ n 18)" — its closing paren skipped over the
#                       auto-closer, so nothing trails the cursor and no
#                       trim is needed
#   Enter           1   unbalanced -> '\n' appended, continuation
#   ")"             0
#   Enter           submits
#
# VHS 0.11 rules this tape obeys
#   * ctrl chords are lowercase. VHS sends Ctrl+Shift+<key> for an
#     uppercase letter, and the terminal frontend only turns ctrl+<letter>
#     into a control byte when shift is NOT held, so "Ctrl+K" would reach
#     the app as nothing at all.
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
#     launch, the continuation hint taking over on the first Enter,
#     "done in {d}ms" when the completed form is submitted, and the
#     continuation hint coming back on the history recall. Everything else
#     — the typed line, the body line, the lone ")" — settles with a
#     bounded Sleep: the input row sits above the status row, and the status
#     row already reads exactly what it is about to read.
#   * a settled frame is never re-taken, retried or filtered, and the eval
#     gate is the status row rather than the literal 60: a wrong or
#     erroring answer is a frame this checkpoint exists to capture, and it
#     is read off the captured PNG by eye.
#   * the launcher prints the exit marker with NO newline. Region.exit
#     parks with "\r\n\r" below the band, so the shell resumes at column 0
#     of a fresh row and, with nothing printed after it, the cursor stays ON
#     the marker row — the row Wait+Line reads.
Output zig-out/visual/stress/repl_multiline.gif

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
Type "printf 'SKRIPT_REPL_EXIT_OK'"
Enter
Show
Wait+Line /Enter: eval/
Sleep 500ms
Screenshot zig-out/visual/stress/repl-01-idle-start.png
Sleep 500ms

# ── line 1: the head of the let, coloured live in the input band ──────
# After Ctrl+k the line is exactly
#     (let ((tag "v1") (n (+ 20 22)))
# with only the outer let still open. The band is the usual 2 rows (input +
# status) because the token at the cursor is empty, and the input row shows
# the live highlighter: "let" blue, "v1" green, 20 / 22 yellow. The status
# row reads the idle hint before and after, so it gates nothing here: the
# typed text is on the input row, above the cursor row, and this frame is
# captured on a bounded settle.
Type '(let ((tag "v1") (n (+ 20 22)))'
Ctrl+k
Sleep 500ms
Screenshot zig-out/visual/stress/repl-02-line1-colored.png
Sleep 500ms

# ── continuation 1 ───────────────────────────────────────────────────
# The buffer is unbalanced, so Enter appends a newline instead of
# evaluating: row 0 switches to the "    · " continuation prompt, the
# status row becomes "multiline: Enter to continue", and the band draws
# only the new (empty) active line. That status change is a real gate: the
# idle hint cannot survive the Enter.
Enter
Wait+Line /multiline: Enter to continue/
Sleep 500ms
Screenshot zig-out/visual/stress/repl-03-continuation-1.png
Sleep 500ms

# ── continuation 2: the body ─────────────────────────────────────────
# The closing paren skips over the auto-inserted one, so the active line
# is exactly "(+ n 18)" with the cursor at its end. Depth is still 1
# (the outer let), which is why the band shows the continuation prompt —
# and it already read that way, so this frame settles and is read by eye.
Type "(+ n 18)"
Sleep 500ms
Screenshot zig-out/visual/stress/repl-04-continuation-2.png
Sleep 500ms

# ── continuation 3: the closing line ─────────────────────────────────
# Still unbalanced -> a third continuation: an empty active line, the
# "    · " prompt and the multiline status hint.
Enter
Sleep 300ms

# The single ")" that closes the let. Neither the typed character nor the
# status row changes what it already read, so this step settles as well.
Type ")"
Sleep 500ms
Screenshot zig-out/visual/stress/repl-05-closing-line.png
Sleep 500ms

# ── evaluate ─────────────────────────────────────────────────────────
# Depth is 0 now, so Enter submits. The band collapses to 2 rows, the
# prompt goes back to "skript> " and the status becomes "done in {d}ms";
# above the band the two query lines are painted by the highlighter (let
# blue, "v1" green, 20/22/18 yellow), followed by " ⇒ 60 (i64)". The gate
# is the status text, never the literal 60: the worker publishes a result
# either way and the next key clears the status, so "done in" is both the
# completion signal and the one row the wait can read. The answer row sits
# above it — a "Parser error:" or "Eval error:" row is captured as it
# stands, never re-taken.
Enter
Wait+Line /done in/
Sleep 500ms
Screenshot zig-out/visual/stress/repl-06-answer.png
Sleep 500ms

# ── history recall ───────────────────────────────────────────────────
# Up reloads the whole committed buffer, so the band shows the
# continuation prompt and the multiline status again. That is a real gate:
# right after the eval the status row read "done in ...ms".
Up
Wait+Line /multiline: Enter to continue/
Sleep 500ms
Screenshot zig-out/visual/stress/repl-07-history-recall.png
Sleep 500ms

# Ctrl+d — lower case: VHS sends Ctrl+Shift+<key> for an upper-case letter
# and the terminal frontend only turns ctrl+<letter> into a control byte
# when shift is NOT held. It quits even with a multi-line buffer pending,
# and the shell then prints the exit marker on the row it resumes. If the
# app ever failed to quit, this wait times out and the tape fails rather
# than passing a session that did not shut down.
Ctrl+d
Wait+Line /SKRIPT_REPL_EXIT_OK/
Sleep 500ms
Screenshot zig-out/visual/stress/repl-08-exit.png
Sleep 500ms
