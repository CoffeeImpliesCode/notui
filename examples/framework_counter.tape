Output zig-out/visual/counter.gif

Set Width 1200
Set Height 480
Set FontSize 20
Set FontFamily "DejaVu Sans Mono"
Set Padding 20
Set TypingSpeed 50ms
Set CursorBlink false
Set Shell "bash"

Hide
Type "export PS1=''; "
Type "printf '\033[H\033[2JSCROLLBACK BEFORE NOTUI\n'; "
Type "./zig-out/bin/example-framework_counter && "
Type "printf '\nNOTUI_EXIT_OK\n'"
Enter
Show
Wait+Screen /count: 0/
Screenshot zig-out/visual/counter-initial.png
Sleep 500ms

Type "iii"
Wait+Screen /count: 3/
Type "d"
Wait+Screen /count: 2/
Screenshot zig-out/visual/counter-updated.png
Sleep 500ms

Type "q"
Wait+Screen /NOTUI_EXIT_OK/
Screenshot zig-out/visual/counter-exit.png
Sleep 500ms
