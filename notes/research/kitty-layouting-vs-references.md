# Kitty layouting: notui vs the references (2026-08-14)

Audit of `src/image.zig` + `src/region.zig` anchor handling + the kitty
examples against the kitty graphics protocol spec (live page,
sw.kovidgoyal.net/kitty/graphics-protocol) and the reference clones:
rockorager-vaxis, meszmate-zigzag, earendil-works-pi (packages/tui),
Textualize-textual. Trigger: the showcase demo renders misplaced /
mis-sized images in real terminals.

## Verdict: three protocol divergences, all in `place`/`transmit` wiring

### 1. `a=p` has NO absolute row/col — position is the cursor
Spec ("Controlling displayed image layout"): *"The image is rendered at
the current cursor position, from the upper left corner of the current
cell."* `c`/`r` are the SPAN in cells — *"c is the number of columns and
r the number of rows. The image will be scaled (enlarged/shrunk) as
needed to fit the specified area."*

notui emitted `a=p,i=200,c=2,r=8` meaning "place at col 2, row 8" —
kitty reads "span 2 columns × 8 rows" and renders at the CURSOR.
Result: every image lands at wherever the cursor was (band bottom) with
a wrong size. This is the demo's visible breakage.

References agree:
- zigzag `placeKittyImage` (src/terminal/terminal.zig:715-721): emits
  `a=p,i=...,q=2,c={width_cells},r={height_cells},C=1,z?,U=1` — c/r are
  cell SIZE; position via `term.moveTo(row,col)` from its own screen
  model (src/core/program.zig:732-792).
- vaxis (image.go:147-154): moves the cursor with
  `CUP(row+1,col+1)` at flush time (vaxis.go:656-686), then writes
  `a=p`; size comes from uploading at exact pixel multiples of the cell
  (native size auto-fits cells). No x/y/w/h/z/q ever emitted. (vaxis
  packs `col<<16|row` into the 32-bit `p` param — the INVERSE of the
  spec's `row<<16|col`; a vaxis bug, not copied.)

### 2. `w`/`h` in a place are a SOURCE-CROP rectangle in pixels
Spec keys table: `x`/`y` = left/top edge of the source area in pixels;
`w`/`h` = width/height of the source area to display (default: entire
image); `c`/`r` = display span in cells. The source rectangle is scaled
to the `c × r` cells. notui's doc comment claimed size is "pixel size
to scale the placed image to" and emitted `w=12,h=12` — kitty reads a
12×12px crop (coincidentally the whole source for our sprites), scaled
to the misread `c`/`r` span.

### 3. Moving/animating a placement needs a placement id (`p=`)
Spec: *"If you send two placements with the same image id and placement
id the second one will replace the first. This can be used to resize or
move placements around the screen, without flicker."* `p` omitted (0)
creates a NEW placement each put. notui re-placed the ball/star every
tick with no `p=` → placements accumulate → trails. Fix: fixed `p=` per
animated sprite (the flip-book reuses ONE `p` while cycling image ids).

## Secondary findings

- **Transmit action**: `t` = transmit only, `T` = transmit AND display
  (spec keys table). notui uses `a=T` → the initial transmit DISPLAYS
  every image at the cursor (stray pile before any placement). pi
  (terminal-image.ts) relies on exactly this: `a=T` at the current
  hardware cursor, no placement at all. notui must use `a=t` + explicit
  placements.
- **Responses**: `q` suppresses responses (0/1/2; 1 = suppress OK).
  notui never reads transmit/place/delete responses; without `q=1`
  every frame's placements spam OK responses into the input stream.
  zigzag uses `q=2`. Use `q=1`.
- **Erase/scroll**: *"The other commands to erase text must have no
  effect on graphics"* — ESC[K / ESC[J / band repaints do NOT destroy
  placements (only ESC[2J / reset / alt-screen do). Placements are
  cell-anchored and scroll with text. notui's inline band model is
  compatible; no change needed.
- **z-index**: default 0 renders ABOVE text; negative = under. notui
  omits z by default → correct.
- **RGB/RGBA transmit must carry s/v** (pixel dims) — notui does.
- **Re-transmit deletes** the image AND all its placements (spec) —
  notui transmits once, fine; the flip-book must NOT re-transmit per
  frame (it doesn't — it pre-transmits 6 frames).
- textual v8.2.8: no kitty-graphics code anywhere (Image widget lived
  in older ~0.6x–1.x tags); not a usable reference.
- vaxis/zigzag/pi all position via the CURSOR (their own screen/line
  model), never via APC coords — no reference uses a CPR-anchored
  absolute-row model like notui's region. notui's anchor bookkeeping
  stays, but the wire must follow the cursor pattern.

## Fix (adopted)

1. `image.zig transmit`: `a=T` → `a=t`, add `q=1`; docs.
2. `image.zig place`: emit `\x1b[{row};{col}H` (move cursor to the
   absolute 1-indexed cell), then
   `\x1b_Ga=p,q=1,i=<id>[,p=<placement>][,c=<w>][,r=<h>][,z=<z>]\x1b\\`
   — `c`/`r` are the span in CELLS; drop the `w`/`h` crop emission;
   add `placement` (p) option. Doc: position = moved cursor; size =
   cells.
3. `image.zig delete`: `q=1`.
4. `region.zig placeAt(w, band_row, col, opts)`: `kitty.place` at
   `anchorRow()+band_row`, then CUP back to the parked cursor
   (band bottom, `anchorRow()+height-1`, col 1) so the next frame's
   relative moves stay valid. The region's "no absolute cursor
   positioning" grep-gate is scoped to its painting; placeAt is the
   documented exception (cursor restored).
5. Showcase + minimal demo: `region.placeAt`; fixed `placement` ids
   (ball 200, star 500, gallery 300/301); cell sizes that fit the
   4-row band (ball/star 2×1 cells, gallery 4×1).
6. Tests: place goldens updated (CUP + q=1 + c/r + p); region.placeAt
   test; transmit goldens (`a=t,q=1`).
