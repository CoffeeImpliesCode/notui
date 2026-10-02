# visual_statusline_narrow.tape — ./zig-out/bin/example-statusline at a
# NARROW viewport, under VHS 0.11.0 (ttyd 1.7.7, ffmpeg 9, DejaVu Sans Mono plus
# the devenv Fontconfig fallbacks). The app paints three rows:
#   row 0  component.StatusBar — left segments " NORMAL ", "notui",
#           "main*" joined by " │ ", plus a right group anchored to the
#           right edge
#           (examples/statusline.zig:203-212). The right tail is
#           "v<version>  col <region.width>", so the frame prints the app's
#           OWN column count: read the fitted grid off the image instead of
#           guessing a number here. At this width the bar has to fold: the
#           left group is kept whole — truncated only if it alone overflows
#           the row — the right group takes the columns that are left and is
#           ellipsized, anchored to the right edge
#           (src/component/status_bar.zig:48-90). Nothing may overlap, bleed
#           past the last column, or leave a gap inside either group.
#   row 1  component.Gauge — label "scan", a 30-cell block fill and a
#           percent suffix, driven by the app as 50 + 45*sin(seconds since
#           the first frame) (:86, :133, :227). The app repaints on every
#           100ms tick, so the meter moves with no input at all.
#   row 2  component.Text with wrap=true — only the first wrapped line of
#           the message, because the region is three rows tall (:233-237).
#           At this width the message wraps much earlier, so this row is the
#           direct read on the wrap invariant, and the 30-cell gauge is
#           clamped to the columns that are left (src/component/gauge.zig:95).
# The palette is picked from the colour profile the terminal reports
# (:224-231); this tape asserts nothing about which profile that is.
#
# The four checkpoints and what they are for:
#   01-gauge-early    the first painted frame, the gauge early in its swing
#   02-gauge-1500ms   the same band 1.5s later, with no key pressed at all
#                     (the narrow clamp must hold across all three frames)
#   03-gauge-3000ms   the same band 3s after the first frame
#   04-exit           "q" quits and the shell prints the exit marker
#
# The gauge value is a function of elapsed WALL time that the tape does not
# control, so no percentage and no fill length is predicted here. The
# invariant to check by eye is a comparison: 01, 02 and 03 must show three
# different meter states, with 02 clearly unlike 01. A later frame that is a
# pixel-identical copy of the first would mean the repaint loop stopped.
#
# No column count is asserted anywhere: VHS calls `term.fit()`, so the grid
# is whatever DejaVu Sans Mono at 20px measures inside the viewport minus the
# padding. The app's own "col N" tail is where the fitted count shows up.
Output zig-out/visual/stress/statusline-narrow.gif

Set Width 400
Set Height 320
Set FontSize 20
Set FontFamily "DejaVu Sans Mono"
Set Padding 20
Set TypingSpeed 10ms
Set CursorBlink false
Set Shell "bash"

# ── launch ─────────────────────────────────────────────────────────────
# The three printf lines are plain shell output, no notui involved: they
# stay in the transcript above the band in every frame below.
Hide
Type "export PS1=''; "
Type "printf '\033[H\033[2J'; "
Type "printf 'S0 STATUSLINE BANNER: printf output, no notui running\n'; "
Type "printf 'S1 notui 0.0.0 - StatusBar + Gauge + Text.wrap\n'; "
Type "printf 'S2 gauge value = 50 + 45*sin(seconds since first frame)\n'; "
Type "./zig-out/bin/example-statusline && printf 'STATUSLINE_NARROW_EXIT_OK'"
Enter
Show
# The wrapped message row is both the readiness marker and the row the
# wrap invariant is read from; "the quick brown fox" survives the wrap to
# the region width at any plausible fit.
Wait+Line /the quick brown fox/
Sleep 500ms
Screenshot zig-out/visual/stress/statusline-narrow-01-gauge-early.png
Sleep 1500ms
Screenshot zig-out/visual/stress/statusline-narrow-02-gauge-1500ms.png
Sleep 1500ms
Screenshot zig-out/visual/stress/statusline-narrow-03-gauge-3000ms.png
Sleep 500ms
# Compare the three: the status bar and the message row must be identical
# in all three (they are static), and only the gauge row may differ. That
# difference is the proof the tick loop is still redrawing. The bar fold and
# the gauge clamp must look the same in all three frames — a group that
# shifts or grows between frames would mean the width clamp leaked.

# ── clean exit ─────────────────────────────────────────────────────────
# "q" is the app's quit key (:157-161) — ctrl+c quits here too, unlike
# examples/prompt.zig. The app parks the cursor below the band, restores
# the terminal, and the shell prints the exit marker one row lower.
# Line reads the parked cursor row, including after scrollback grows.
Type "q"
Wait+Line /STATUSLINE_NARROW_EXIT_OK/
Sleep 500ms
Screenshot zig-out/visual/stress/statusline-narrow-04-exit.png
Sleep 500ms
