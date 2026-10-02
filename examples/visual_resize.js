// notui live visual stress driver — capture recipes, not a test
// framework. It drives the real example binaries through a real ttyd pty
// in a real Chromium tab and resizes the REAL viewport (xterm.js
// FitAddon -> RESIZE_TERMINAL -> TIOCSWINSZ -> real SIGWINCH). It never
// judges a picture: each checkpoint records the real terminal state next
// to the invariant the parent should look for. It starts no service of
// its own.
//
// THREE recipes over the same helpers, independently runnable:
//   runResizeStress   — GEOMETRY: 16 settled PNGs across three
//     scenarios (wide/narrow/short refits, pre-app banner, history).
//   runTemporalStress — TIME: hooks the real window.term.onRender in the
//     page main world and records every observed render event, text, cell
//     styles, and the input stage in flight. Events can coalesce app writes;
//     stage labels do not establish which key caused a paint. Video retains
//     the visible surface, including the half-drawn band between refits.
//   runOwnershipResizeStress — OWNERSHIP: three scenarios that put a band
//     through a physical height cycle, a width roundtrip and one mixed
//     ASCII + width-two glyph input line carried across a one-row physical
//     clip taken at the wide width, an odd-width narrowing while the band
//     is still one row, a widening while it is still one row, and the
//     height restore. Every buffer row is recorded (wrap flag, used cells,
//     inverse runs) so archived band groups, terminal-reflowed band rows
//     and residue are visible as what they are. 36 committed marker rows
//     are printed before each app launch, the binary is identified by the
//     SHA-256 of the bytes launched, and the contracts (markers exactly
//     once, the app's own CLIPPED input row, the whole typed line as the
//     terminal's own reflow of the row the band retired, one status row
//     in the whole buffer after the restore, the popup rows and
//     selection, the roundtrip, no stale owned rows, a zero exit code)
//     are checked automatically and written to the report before anything
//     is thrown.
//
// DECLARED NATIVE CAPACITY: every recipe that launches a notui REGION app
// (the statusline and the skript REPL) launches it with
// `--terminal-scrollback-rows=N`, where N is READ from that tab's own
// `window.term.options.scrollback` — the scrollback the terminal really has,
// never a constant of this driver — and the value and the exact command are
// recorded in that recipe's report. Anything that is not a region app (the
// prompt/editor example) is launched with no argument at all.
// Native opt-in also declares a transcript-tail band with unused terminal-
// generated padding below and source-preserving oldest-row-only eviction.
// Each recipe owns a fresh PTY and prints its markers ABOVE the launch point.
// Installed xterm corrupts later rows in some capped WIDTH overflows; these
// live recipes avoid that terminal defect. Conforming overflow is covered by
// the independent consumer model. No global tool or terminal source is patched.
//
// ttyd, started by the parent in the devenv shell (repo root as cwd):
//   ttyd -i 127.0.0.1 -p 7681 -W -t rendererType=canvas \
//     -t 'fontFamily="DejaVu Sans Mono"' -t fontSize=16 -t lineHeight=1.2 \
//     -t cursorBlink=false -t scrollback=20000 -t disableResizeOverlay=true \
//     -t disableLeaveAlert=true -t disableReconnect=true \
//     -t titleFixed=notui-resize-stress bash --noprofile --norc
// No -o/--once and no -q/--exit-no-conn: one tab per scenario means one fresh
// pty each, and either flag would kill the server on the first disconnect.
// rendererType=canvas is ttyd's no-WebGL fallback; disableResizeOverlay keeps
// its 300ms "COLSxROWS" overlay out of the frames; scrollback must outlive
// scenario 2's overflow.
//
// ttyd 1.7.7 has no exposeTerm option: Xterm.open() assigns `window.term`
// unconditionally (html/src/components/terminal/xterm/index.ts), so the real
// xterm.js buffer is read from there — no fallback, a missing window.term
// fails the first hard wait. Colours reflect the capabilities advertised by
// ttyd; the capture records the actual terminal rather than assuming a profile.
//
// Terminal state is read with `tab.evaluate`, the PAGE MAIN WORLD, because
// that is the only world with ttyd's `window.term`: a raw `page.evaluate`
// inside `tab.run` is isolated and reports `window.term === undefined`. The
// isolated world is used only where no page global is needed — the 2-RAF
// resize wait, `document.fonts.ready`, and the real mouse/keyboard/screenshot
// calls.
//
// CDP lifecycle: `app.cdp_url` ATTACHES to a target this module did not
// create, so nothing here creates, closes or serves one. `browser.open`'s
// `viewport` is metadata only on such a target: every scenario sets the real
// size through the page and reads the fitted geometry back from the main
// world. The parent owns the ttyd service and kills its Chromium.
//
// CHECKPOINTS (16 PNGs, resize-<scenario>-<name>.png under outputDir):
//   resize-statusline-{wide,narrow,wide-restored,exit}
//   resize-prompt-{preapp-banner,history-wide,pending-wide,narrow-short,
//                   restored-wide,cleared,exit}
//   resize-repl-{popup-open,popup-short,popup-restored,popup-dismissed,exit}
//
// TEMPORAL CHECKPOINTS (12 PNGs, temporal-<scenario>-<name>.png, plus one
// temporal-<scenario>-timeline.json and one temporal-<scenario>.webm per
// scenario):
//   temporal-statusline-{preapp-marker,anim-a,anim-b,cycle-1-narrow,
//                        cycle-3-wide,exit}
//   temporal-repl-{midline-cycled,cleared,popup-reopen,popup-short,
//                  evaluated,exit}
//
// OWNERSHIP CHECKPOINTS (25 PNGs, own-<phase>-<scenario>-<name>.png under
// outputDir, plus one ownership-<phase>-report.json):
//   own-<phase>-{repl,statusline,mix}-preapp-markers
//   own-<phase>-repl-{wide-popup-selected-third,height-6,height-1,
//                     height-6-again,wide-restored,escape-dismissed-idle,
//                     escape-repeat-dismissed,edit-rearms-popup,tab-accepted,
//                     width-narrow,width-restored-wide,exit}
//   own-<phase>-statusline-{wide,narrow,wide-restored,exit}
//   own-<phase>-mix-{wide-mixed-input,narrow-odd,clip-short,clip-widened,
//                   height-restored,exit}
//
// Eval, JS kernel (no import side effects):
//   const { runResizeStress } = await import(
//     `${process.cwd()}/examples/visual_resize.js`);
//   display(await runResizeStress(browser, {
//     baseUrl: "http://127.0.0.1:7681", outputDir: "zig-out/visual/stress",
//     app: { cdp_url: "http://127.0.0.1:17790" },   // optional
//   }));
//
//   const { runTemporalStress } = await import(
//     `${process.cwd()}/examples/visual_resize.js`);
//   display(await runTemporalStress(browser, {
//     baseUrl: "http://127.0.0.1:17803", outputDir: "zig-out/visual/temporal",
//     scenarios: ["repl"],                             // optional: either one
//     app: { cdp_url: "http://127.0.0.1:17790" },      // optional
//   }));
//   // then READ every file listed in report.checkpoints[].file
//   // temporal also saves timelines[].file (frames) and timelines[].video
//
//   const { runOwnershipResizeStress } = await import(
//     `${process.cwd()}/examples/visual_resize.js`);
//   display(await runOwnershipResizeStress(browser, {
//     baseUrl: "http://127.0.0.1:17803", outputDir: "zig-out/visual/ownership",
//     phase: "before",                                // or "after"
//     binaryPrefix: ["/nix/store/.../ld-linux-x86-64.so.2",  // optional
//                    "--library-path", "/nix/store/..."],     // argv prefix
//     app: { cdp_url: "http://127.0.0.1:17790" },      // optional
//   }));
//   // then READ every file listed in checkpoints[].file
//   // failures, the binaries' sha256 and the per-checkpoint checks are in
//   // ownership-<phase>-report.json even when the call throws
//
// API: runResizeStress(browser, { baseUrl, outputDir, app?, repoRoot? })
//   browser: the managed handle; baseUrl: the ttyd URL; outputDir: PNG
//   directory, created if missing, resolved against cwd(); app: optional
//   browser.open `app` — an endpoint to ATTACH to, never a process or target
//   this module launches; repoRoot: defaults to cwd() — the binaries run by
//   absolute path, so ttyd's cwd is irrelevant. Returns { baseUrl, outputDir,
//   wide, narrow, checkpoints, scenarios }, each checkpoint { scenario, name,
//   file, cols, rows, viewport, screen, cursor, expected } (+ buffer on the
//   two history frames), all measured rather than assumed, and `scenarios[]`
//   carries each scenario's declared native capacity and the exact commands
//   typed: every region app (the statusline and the REPL) is launched with
//   `--terminal-scrollback-rows=N` and N is read from that tab's own
//   `window.term.options.scrollback`, while the prompt/editor example is
//   launched with no argument at all. Throws on infrastructure loss and on a
//   missing or non-zero app exit, always after that step's PNG exists; a soft
//   wait (a refit, an exit marker) photographs the defect instead of losing
//   the frame.
//
// API: runTemporalStress(browser, options) — the same options plus
//   scenarios? (default both; either alone runs), maxRenders? (20000
//   frames), maxBufferRows? (512 non-empty buffer rows per snapshot),
//   keyGapMs? (10; keys are spaced 10-20ms apart), midlineCycles? (8),
//   animationMs? (1500). Returns { baseUrl, outputDir, wide, narrow,
//   report, checkpoints, timelines }: `report` is a temporal-report.json
//   manifest; `timelines[]` carries { scenario, file, video, renders,
//   payloads, renderOverflow, renderDropped, bufferOverflow,
//   bufferDroppedRows, bufferTruncatedSnapshots, stages, nativeCapacity,
//   launchCommands } — the same declared capacity and exact launch commands
//   the resize recipe reports, and the manifest repeats them per scenario —
//   and `stages[]` is the per-input render index ({ stage, renders, first })
//   so every key and every refit sent during the run is addressable by name.
//   Either bound failing FAILS the scenario after its JSON is on disk, each with
//   its own reason: past maxRenders nothing is captured at all, and past
//   maxBufferRows a snapshot keeps its newest buffer rows and marks
//   bufferTotal/bufferKept/bufferDropped on itself. A failed live exit
//   throws only once the PNG, the timeline and the video are all saved.
//
// API: runOwnershipResizeStress(browser, options) — { baseUrl, outputDir,
//   phase, binaryPrefix?, app?, repoRoot?, maxBufferRows? }. phase is
//   REQUIRED and must be 'before' or 'after': it is the caller's own label
//   for the build under test, it names the PNGs and the report so the two
//   runs never overwrite each other, and no timestamp is invented for it.
//   binaryPrefix is an optional argv prefix for a native binary that cannot
//   start inside ttyd's environment (a Debug build needs its real dynamic
//   loader and --library-path); every element is shell quoted, and the
//   default is the plain direct launch the other two recipes always type.
//   Every ownership launch carries `--terminal-scrollback-rows=N`, with N
//   READ from that tab's own `window.term.options.scrollback` (never a
//   constant of this driver, and an unreadable one is a hard failure): it
//   is the declared native retention capacity the examples turn into
//   `Region.TerminalReflow .{.non_cursor_rows=.{.scrollback_rows=N}}`, and
//   without the argument they run `.none`. The driver records the exact
//   argv it typed and nothing else: what a loader prefix does to the
//   program's own argv is the example's question to answer with a real
//   binary, not this driver's to assume.
//   maxBufferRows? (512 recorded buffer rows per checkpoint; the marker
//   counts are taken over the whole buffer, so the bound can never hide a
//   lost or doubled marker, and a truncated record FAILS its checkpoint).
//   Three scenarios, one fresh pty each: the REPL popup across the measured
//   full height → 6 → 1 → 6 → full height with the third candidate selected,
//   the Escape dismissal while idle and the edit + Tab that re-arm and
//   accept completion, then a wide → narrow → wide reflow; the statusline's
//   own wide → narrow → wide width roundtrip; and the mixed line — 47 ASCII
//   columns + 37 width-two glyphs + the 8-column prompt, 129 columns — typed
//   wide, narrowed to a MEASURED odd column count, clipped into 3 physical
//   rows, widened again while that clip's retired rows are still hidden,
//   and height-restored. Every cols/rows figure is derived from the live
//   page and recorded as measured. Every checkpoint records the whole
//   bounded buffer (each row with its wrap flag, used cells, inverse runs and
//   kind), the measured geometry, the group structure (the bottom-most group
//   the terminal is SHOWING is live; a group above it is an archived band —
//   visible residue while it is on screen, recorded either way, and never
//   called history just because the terminal scrolled past it), the LOGICAL
//   band rows with the physical rows behind them and the join that produced
//   each one, the marker counts and this driver's own clock.
//   Returns { baseUrl, outputDir, phase, wide, narrow, report, markers,
//   scenarios, checkpoints }; `scenarios[]` carries the launched binary's
//   path, realpath, size and sha256, the declared capacity and the exact
//   commands typed. Every contract failure and every scenario crash is
//   written to the report — and every PNG is on disk — before the run throws.

import { createHash } from 'node:crypto';
import { mkdir, readFile, realpath, stat, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';

// Fixed readable pixel sizes; the SHORT height is computed per tab from the
// real cell height + page chrome (shortViewport) — never calibrated.
const WIDE = Object.freeze({ width: 1200, height: 700 });
const NARROW = Object.freeze({ width: 520, height: 700 });
const SHORT_ROWS = 6;
const TYPE_DELAY_MS = 10; // per character: keeps the pty input queue fed
const SETTLE_MS = 500; // bounded app settle after every geometry change
const FIRST_FRAME_MS = 60_000; // first app paint (the skript prelude is slow)
const FOLLOW_MS = 8_000; // viewport change -> xterm refit, or focus
const EXIT_MS = 30_000; // app exit -> the launcher's rc marker
const SOFT_MS = 4_000; // visual settle whose miss is still captured

const BIN = {
  statusline: 'example-statusline',
  prompt: 'example-prompt',
  repl: 'example-skript-repl',
  // The ownership recipe's third scenario types one ASCII + width-two glyph
  // input line and puts it through a width/height cycle: the same REPL
  // binary, so both ownership scenarios hash to the same build.
  mix: 'example-skript-repl',
};

// runTemporalStress bounds. maxRenders is sized for a WHOLE scenario (both
// examples repaint ~10x/second on their own tick plus once per key), so the
// default retains everything a full run emits. maxBufferRows bounds one
// snapshot's non-empty buffer rows; the real count travels with the
// snapshot, so a truncated buffer is visible rather than silent.
const TAP = Object.freeze({
  key: '__notuiTemporalTap',
  maxRenders: 20_000,
  maxBufferRows: 512,
  pullChunk: 1 << 20, // JSON characters pulled out of the page at a time
});

// Real-key cadence for the rapid edit bursts: key i waits KEY_GAP_MIN_MS +
// (i mod span) ms after it is sent, so the burst lands inside the app's
// repaint interval instead of one key per frame.
const KEY_GAP_MIN_MS = 10;
const KEY_GAP_MAX_MS = 20;
const MIDLINE_CYCLES = 8;
const ANIMATION_MS = 1500;
const REPL_FORM = '(+ 20 22)'; // ⇒ 42
const REPL_OPEN_FORM = '(+ 40'; // Delete the auto-inserted ')' before Enter to continue.
const REPL_CLOSE_FORM = ' 20)'; // ⇒ 60, as a two-row form
const REPL_QUOTED = '(concat "héllo wörld" "中文 ok")';

/** Key-gap bounds derived from a requested base, always inside 10..20ms. */
function gapBounds(baseMs) {
  const lo = Math.max(
    1,
    Math.min(KEY_GAP_MAX_MS, Math.floor(Number(baseMs) || KEY_GAP_MIN_MS)),
  );
  return { lo, span: KEY_GAP_MAX_MS - lo + 1 };
}

/** A positive integer bound, or the default when the option is unusable. */
const bound = (value, fallback) => {
  const n = Math.floor(Number(value));
  return Number.isFinite(n) && n > 0 ? n : fallback;
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const shq = (s) => `'${String(s).replaceAll("'", `'\\''`)}'`;

/** The real xterm.js state, read from ttyd's `window.term`. */
async function readState(tab) {
  // Direct `tab.evaluate` runs in the PAGE MAIN WORLD, which is the only world
  // where ttyd's `window.term` exists; a raw `page.evaluate` inside `tab.run`
  // is isolated and would report `window.term === undefined`.
  return tab.evaluate(() => {
    const term = window.term;
    if (!term || !term.buffer || !term.buffer.active) return { ready: false };
    const buf = term.buffer.active;
    const row = (y) => {
      const line = buf.getLine(y);
      return line ? line.translateToString(true) : '';
    };
    const screen = [];
    for (let y = buf.viewportY; y < buf.viewportY + term.rows; y++) screen.push(row(y));
    const lines = [];
    for (let y = 0; y < buf.length; y++) {
      const text = row(y);
      if (text.trim()) lines.push(text);
    }
    const pick = (sel) => document.querySelector(sel);
    const grid = pick('.xterm-screen');
    const cbox = grid ? grid.getBoundingClientRect() : null;
    const container = pick('#terminal-container');
    const bbox = container ? container.getBoundingClientRect() : null;
    const terminal = pick('.xterm');
    const bottomPadding = terminal ? Number.parseFloat(getComputedStyle(terminal).paddingBottom) : 0;
    return {
      ready: true,
      cols: term.cols,
      rows: term.rows,
      // The size the page really has, so a checkpoint shows the geometry that
      // produced it instead of the geometry that was asked for.
      viewport: { width: window.innerWidth, height: window.innerHeight },
      screen,
      lines,
      cursor: { x: buf.cursorX, y: buf.baseY + buf.cursorY - buf.viewportY },
      focused: document.activeElement?.tagName === 'TEXTAREA',
      // Measure the grid's cells and CSS padding. Before a refit the grid
      // may overflow its container; that overflow is not negative chrome.
      cellHeight: cbox && term.rows ? cbox.height / term.rows : 0,
      // The measured cell width, so a recipe can walk the viewport by whole
      // cells (the odd-column fit does exactly that) instead of by a guess.
      cellWidth: cbox && term.cols ? cbox.width / term.cols : 0,
      chrome: bbox && cbox
        ? cbox.top + Math.max(0, innerHeight - bbox.bottom) + bottomPadding
        : 0,
    };
  });
}

/**
 * Bounded poll of the real terminal state. A hard wait is an infrastructure
 * gate (window.term, the first fitted geometry, focus, the first app frame)
 * and throws; a soft wait returns the last state it saw, so a clipped, stale
 * or otherwise defective frame is still captured for the parent to judge.
 */
async function waitScreen(tab, what, ok, budgetMs, hard = false) {
  const deadline = Date.now() + budgetMs;
  for (;;) {
    const state = await readState(tab);
    if (!state.ready) {
      if (Date.now() > deadline) {
        throw new Error(`[resize] ${what}: no window.term — ttyd's terminal never came up`);
      }
    } else if (ok(state)) return state;
    if (Date.now() > deadline) {
      if (hard)
        throw new Error(
          `[resize] ${what}: gave up after ${budgetMs}ms; screen=${JSON.stringify(state.screen)}`,
        );
      return state;
    }
    await sleep(150);
  }
}

const press = (tab, ...keys) =>
  tab.run(
    async ({ page }, ks) => {
      for (const key of ks) await page.keyboard.press(key);
    },
    { args: [keys] },
  );

const ctrl = (tab, key) =>
  tab.run(
    async ({ page }, k) => {
      await page.keyboard.down('Control');
      try {
        await page.keyboard.press(k);
      } finally {
        await page.keyboard.up('Control');
      }
    },
    { args: [key] },
  );

const type = (tab, text) =>
  tab.run(async ({ page }, t, delay) => page.keyboard.type(t, { delay }), {
    args: [text, TYPE_DELAY_MS],
  });

/** `type` at an explicit per-character delay. */
const typeAt = (tab, text, delay) =>
  tab.run(async ({ page }, t, d) => page.keyboard.type(t, { delay: d }), {
    args: [text, delay],
  });

/**
 * Real key presses with a 10-20ms gap after each one, so a burst of keys
 * arrives WHILE the app is repainting. Same `page.keyboard` path as
 * `press`, only paced; control chords still go through `ctrl`.
 */
const pressSpaced = (tab, baseMs, keys) => {
  const { lo, span } = gapBounds(baseMs);
  return tab.run(
    async ({ page }, ks, from, every) => {
      for (let i = 0; i < ks.length; i++) {
        await page.keyboard.press(ks[i]);
        await new Promise((done) => setTimeout(done, from + (i % every)));
      }
    },
    { args: [keys, lo, span] },
  );
};

/** Real viewport change; xterm's FitAddon refits on the window resize event. */
async function resize(tab, viewport) {
  await tab.run(
    async ({ page }, vp) => {
      await page.setViewport({ width: vp.width, height: vp.height });
      // Two frames: FitAddon runs in the window resize handler.
      await page.evaluate(
        () => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))),
      );
    },
    { args: [viewport] },
  );
}

/**
 * Resize, then wait — softly — until the terminal acknowledges the new
 * geometry with a DIFFERENT one. A refit that never lands (the short
 * terminals are exactly where that happens) is a defect this run exists to
 * photograph, so the frame is captured and its real cols/rows/viewport go
 * into the checkpoint; a resize that landed twice in a row is visible in
 * those numbers instead of being thrown away.
 */
async function resizeAndAck(tab, viewport, what) {
  const before = await readState(tab);
  await resize(tab, viewport);
  return waitScreen(tab, what, (s) => s.cols !== before.cols || s.rows !== before.rows, FOLLOW_MS);
}

/**
 * The real geometry once it has STOPPED moving: two reads a settle apart
 * that agree on cols and rows. A refit that lands later than that is a
 * defect the checkpoint photographs, not a wait that never ends.
 */
async function settledState(tab, what, budgetMs = FOLLOW_MS) {
  const deadline = Date.now() + budgetMs;
  let last = await readState(tab);
  while (Date.now() < deadline) {
    await sleep(SETTLE_MS / 2);
    const now = await readState(tab);
    if (!now.ready) break;
    if (now.cols === last.cols && now.rows === last.rows) return now;
    last = now;
  }
  return last;
}

/**
 * A narrow viewport whose FITTED column count is ODD.
 *
 * xterm's FitAddon derives cols from the available width, so an odd count is
 * measured, never assumed: the walk starts at NARROW and steps the viewport
 * by the MEASURED cell width until the terminal reports an odd number of
 * columns. The result carries the viewport and the attempt count, so a
 * column count the walk could not make odd is visible in the checkpoint
 * instead of being papered over.
 */
async function fitOddCols(tab, what, base = NARROW, tries = 8) {
  let viewport = { ...base };
  let state = null;
  for (let attempt = 1; attempt <= tries; attempt++) {
    await resize(tab, viewport);
    await sleep(SETTLE_MS);
    state = await settledState(tab, `${what} fit ${attempt}`);
    if (state.cols % 2 === 1)
      return { state, viewport, attempts: attempt, cellWidth: state.cellWidth, odd: true };
    const cell = Math.max(1, Math.round(state.cellWidth));
    viewport = { ...viewport, width: viewport.width + cell };
  }
  return { state, viewport, attempts: tries, cellWidth: state?.cellWidth ?? 0, odd: false };
}

/**
 * `width` defaults to WIDE.width; pass the width a short geometry has to
 * keep so a height clip can be taken at the NARROW column count the recipe
 * just measured.
 */
function rowsViewport(state, rows, width = WIDE.width) {
  const { cellHeight, chrome } = state.geometry ?? state;
  // +2px so subpixel truncation cannot drop a row.
  return { width, height: Math.ceil(rows * cellHeight + chrome) + 2 };
}

/** `rowsViewport` at SHORT_ROWS — the short geometry the first two recipes use. */
function shortViewport(state) {
  return rowsViewport(state, SHORT_ROWS);
}

/**
 * The real PNG, written straight into the approved outputDir through
 * `page.screenshot({ path })` — never a helper default that would land in
 * the browser's own temp location.
 */
const screenshot = (tab, file) =>
  tab.run(
    async ({ page }, path) => {
      await page.evaluate(() => (document.fonts ? document.fonts.ready : null));
      await page.screenshot({ path, type: 'png' });
    },
    { args: [file] },
  );

/**
 * One checkpoint: bounded settle, re-read the state that produced the frame,
 * save the real PNG. `withBuffer` also records every non-empty row of the
 * xterm buffer (viewport + scrollback), where the parent must judge
 * committed-history duplication.
 */

async function shot(ctx, scenario, name, expected, withBuffer = false) {
  await sleep(SETTLE_MS);
  const state = await readState(ctx.tab);
  const file = resolve(
    ctx.outputDir,
    `${ctx.pngPrefix ?? 'resize'}-${scenario}-${name}.png`,
  );
  await screenshot(ctx.tab, file);
  const checkpoint = {
    scenario,
    name,
    file,
    cols: state.cols,
    rows: state.rows,
    viewport: state.viewport,
    screen: state.screen,
    cursor: state.cursor,
    expected,
    cellHeight: state.cellHeight,
    chrome: state.chrome,
    at: Date.now(),
  };
  return withBuffer ? { ...checkpoint, buffer: state.lines } : checkpoint;
}

/**
 * The exit frame. The launcher's `rc=` marker — anchored, with a NUMERIC rc,
 * so the echoed launch command can never satisfy it — is the only proof the
 * app really exited, and a non-zero rc is a FAILED capture, not a silent
 * success. The wait is soft and the PNG comes first: an app that never
 * reached its marker is a frame to photograph, and the throw happens after
 * that file exists.
 */
async function exitShot(ctx, scenario, marker, expected) {
  const exitPattern = new RegExp(`^VISUAL_EXIT ${marker} rc=\\d+$`);
  const seen = (s) => s.screen.some((line) => exitPattern.test(line));
  await waitScreen(ctx.tab, `${scenario} exit marker`, seen, EXIT_MS);
  const checkpoint = ctx.timelineFile
    ? await temporalShot(ctx, scenario, 'exit', expected)
    : await shot(ctx, scenario, 'exit', expected);
  const exitLine = checkpoint.screen.find((line) => exitPattern.test(line));
  if (!exitLine) {
    throw new Error(
      `[resize] ${scenario}: no VISUAL_EXIT ${marker} rc=<number> within ${EXIT_MS}ms; screen=${JSON.stringify(checkpoint.screen)}`,
    );
  }
  const rc = /rc=(\d+)$/.exec(exitLine)?.[1] ?? null;
  if (rc !== '0') {
    throw new Error(
      `[resize] ${scenario}: app exited rc=${rc}; screen=${JSON.stringify(checkpoint.screen)}`,
    );
  }
  return checkpoint;
}

/**
 * The command typed into the ttyd bash; typed keys are echoed before this.
 * `prefix` is the caller's optional argv prefix for a native binary that
 * will not start on its own inside ttyd's environment (a Debug build needs
 * its real dynamic loader and library path). `appArgs` are the binary's own
 * arguments, AFTER the path. Every element is shell quoted, so a path, a
 * flag or a value with spaces cannot break the command; the default prefix
 * and args are empty, which is the plain `<binary>; rc=$?; ...` any program
 * that is not a notui region app is launched with.
 */
const launchCmd = (binAbs, marker, prefix = [], appArgs = []) =>
  `${[...prefix, binAbs, ...appArgs].map(shq).join(' ')}; rc=$?; printf '\\nVISUAL_EXIT ${marker} rc=%s\\n' "$rc"`;

/**
 * The launch command for a notui REGION app (the REPL, the statusline): the
 * binary plus its own `--terminal-scrollback-rows=N` argument, with N read
 * from this tab's live scrollback. Every recipe that launches one of these
 * two binaries goes through here, so no scenario can quietly run the
 * examples' `.none` policy because it forgot the flag.
 *
 * Anything that is NOT one of those two (the prompt/editor example, any
 * other program) is launched by the plain `launchCmd` with no argument at
 * all. The typed command is remembered on `ctx.commands` when the recipe
 * records them.
 */
const launchApp = (ctx, binAbs) => {
  if (!ctx.capacity)
    throw new Error(
      `[${ctx.recipe ?? 'resize'}] ${ctx.scenario}: no declared native capacity for this launch; read this tab's scrollback before launching the app`,
    );
  const command = launchCmd(binAbs, ctx.marker, ctx.binaryPrefix ?? [], [ctx.capacity.flag]);
  if (ctx.commands) ctx.commands.push(command);
  return command;
};

/**
 * Read this tab's scrollback and record it as the DECLARED native retention
 * capacity every region app in this tab is launched with. One read per tab,
 * before the app exists; an unreadable one is a hard failure, because a
 * constant of this driver would be a claim about a terminal it has not
 * seen.
 */
async function declareCapacity(ctx, booted, label) {
  const read = await readCapacity(ctx.tab);
  if (!read.ready)
    throw new Error(
      `[${label}] ${ctx.scenario ?? ''}: this terminal reports no usable scrollback capacity (${read.why ?? 'unusable read'}), so the app cannot be launched with its declared native retention capacity; this driver passes no constant of its own`,
    );
  ctx.capacity = capacityRecord(read, booted);
  return ctx.capacity;
}

/** Real mouse click on the ttyd terminal, then real keyboard focus. */
async function focusTerminal(tab) {
  await tab.run(async ({ page }) => {
    const el = await page.$('#terminal-container');
    if (!el) throw new Error('[resize] ttyd #terminal-container not found');
    const box = await el.boundingBox();
    if (!box) throw new Error('[resize] #terminal-container has no box');
    await page.mouse.click(box.x + 8, box.y + 8);
  });
  await waitScreen(tab, 'terminal focus', (s) => s.focused, FOLLOW_MS, true);
}

/**
 * One ttyd tab = one pty = one fresh bash per scenario.
 *
 * Geometry comes first and comes from the page: for an attached
 * `app.cdp_url` target, `browser.open`'s `viewport` is metadata the driver
 * never applies, so WIDE is set with the real resize helper and the fitted
 * terminal is read back from the page world before anything is typed.
 * Focus readiness is DOM (xterm's own textarea), never an ideal app
 * screen, so a half-drawn or short screen is still photographed.
 *
 * `app.cdp_url` ATTACHES to a target this module did not create, so it is
 * never closed here — `tab.close()` only releases the attachment (or the
 * managed tab of a driver-launched browser), and the parent owns the ttyd
 * service and the whole Chromium process. `ctx.tabPrefix` is what keeps
 * runResizeStress's tabs and runTemporalStress's tabs apart.
 */
async function openScenarioTab(ctx, name) {
  return ctx.browser.open({
    name: `${ctx.tabPrefix ?? 'resize'}-${name}`,
    url: ctx.baseUrl,
    headed: false,
    viewport: WIDE,
    allowed_domains: [ctx.host],
    ...(ctx.app ? { app: ctx.app } : {}),
  });
}

async function runScenario(ctx, name, body) {
  const tab = await openScenarioTab(ctx, name);
  const scenarioCtx = {
    ...ctx,
    tab,
    scenario: name,
    recipe: 'resize',
    marker: `RESIZE-${name.toUpperCase()}`,
    capacity: null,
    commands: [],
  };
  const checkpoints = [];
  try {
    await resize(tab, WIDE);
    // Hard, but infrastructure only: a live window.term with a fitted
    // geometry. The generous budget is a slow first load, never a wait for
    // any app output.
    const booted = await waitScreen(
      tab,
      'ttyd terminal boot',
      (s) => s.cols > 0 && s.rows > 0,
      FIRST_FRAME_MS,
      true,
    );
    // This tab's own scrollback is the declared native retention capacity
    // every region app launched in it is told about.
    await declareCapacity(scenarioCtx, booted, 'resize');
    await focusTerminal(tab);
    await body(scenarioCtx, checkpoints);
  } finally {
    await tab.close();
  }
  return {
    checkpoints,
    capacity: scenarioCtx.capacity,
    commands: [...scenarioCtx.commands],
  };
}

// ── scenario 1: statusline, wide → narrow → wide → exit ───────────────────
// statusline.zig draws a 3-row band (StatusBar / Gauge / wrapped Text).
// StatusBar keeps its left group whole and drops the right tail when the line
// is too narrow, so the narrow frame is the interesting one.
async function statuslineBody(ctx, checkpoints) {
  const bin = resolve(ctx.repoRoot, 'zig-out/bin', BIN.statusline);
  const capture = (name, expected) => shot(ctx, 'statusline', name, expected);
  await type(ctx.tab, launchApp(ctx, bin));
  await press(ctx.tab, 'Enter');
  await waitScreen(
    ctx.tab,
    'statusline first frame',
    (s) => s.screen.some((line) => line.includes('NORMAL')),
    FIRST_FRAME_MS,
    true,
  );

  checkpoints.push(
    await capture(
      'wide',
      '3 consecutive inline rows: statusbar with right-aligned col {cols}, gauge, wrapped message; content above remains intact',
    ),
  );

  await resizeAndAck(ctx.tab, NARROW, 'statusline narrow');
  checkpoints.push(
    await capture(
      'narrow',
      'strategy-2 clear + redraw at 520px: no stale wide row survives; judge whether the right tail is dropped or clipped and whether all 3 band rows survive',
    ),
  );

  await resizeAndAck(ctx.tab, WIDE, 'statusline wide-restored');
  checkpoints.push(
    await capture(
      'wide-restored',
      'back at 1200px with the layout of the first wide frame; the gauge animates, everything else must match',
    ),
  );

  await press(ctx.tab, 'q');
  checkpoints.push(
    await exitShot(
      ctx,
      'statusline',
      ctx.marker,
      'q quit: cursor parked below the band, terminal restored, launcher printed rc=0',
    ),
  );
}

// ── scenario 2: prompt, pre-app banner + pending Unicode line ─────────────
// prompt.zig: Enter appends the typed line ABOVE the 1-row band in
// scrollback; ctrl+c clears the whole line wherever the cursor sits (there is
// no ^U handler); ctrl+d always quits.
async function promptBody(ctx, checkpoints) {
  const bin = resolve(ctx.repoRoot, 'zig-out/bin', BIN.prompt);
  const capture = (name, expected, withBuffer) => shot(ctx, 'prompt', name, expected, withBuffer);
  const banner = ['VRQ2-PREAPP-BANNER-A', 'VRQ2-PREAPP-BANNER-B'];

  // Banner rows printed by bash BEFORE the app starts: this frame shows
  // terminal content no notui frame has touched yet.
  await type(
    ctx.tab,
    `export PS1=''; printf '\\e[H\\e[2J\\e[3J'; printf '%s\\n' ${banner.map(shq).join(' ')}`,
  );
  await press(ctx.tab, 'Enter');
  await waitScreen(
    ctx.tab,
    'prompt banner',
    (s) => s.screen.some((line) => line.includes(banner[0])),
    FIRST_FRAME_MS,
    true,
  );
  checkpoints.push(
    await capture(
      'preapp-banner',
      'two bash-printed banner rows on a cleared terminal, before the app has painted anything',
    ),
  );

  await type(ctx.tab, launchCmd(bin, ctx.marker));
  await press(ctx.tab, 'Enter');
  const wide = await waitScreen(
    ctx.tab,
    'prompt first frame',
    (s) => s.screen.some((line) => line.startsWith('prompt >')),
    FIRST_FRAME_MS,
    true,
  );

  // Overflow the buffer with uniquely numbered lines, so the committed
  // history can be counted in the recorded scrollback.
  const submitted = wide.rows + 8;
  for (let i = 1; i <= submitted; i++) {
    await type(ctx.tab, `vrlq-${String(i).padStart(4, '0')}`);
    await press(ctx.tab, 'Enter');
  }
  const last = `vrlq-${String(submitted).padStart(4, '0')}`;
  await waitScreen(
    ctx.tab,
    `prompt history of ${submitted} lines`,
    (s) => s.screen.some((line) => line.includes(last)),
    SOFT_MS,
  );
  checkpoints.push(
    await capture(
      'history-wide',
      `all ${submitted} numbered lines sit above the 1-row band, each exactly once, oldest spilled into scrollback — count them in the recorded buffer`,
      true,
    ),
  );

  await type(ctx.tab, 'PENDING-VRQ2 café ✓ 中文 tail 0123456789abcdefghijklmnopqrstuvwxyz-END');
  checkpoints.push(
    await capture(
      'pending-wide',
      'long Unicode input fits the wide band and will clip at the narrow width; nothing new in scrollback',
    ),
  );

  const short = shortViewport(wide);
  await resizeAndAck(ctx.tab, { ...short, width: NARROW.width }, 'prompt narrow-short');
  checkpoints.push(
    await capture(
      'narrow-short',
      `520px wide, ${short.height}px tall: the 1-row band and its pending line are all that can survive a 6-row terminal — a wrapped or clipped band row is evidence, judge the image`,
    ),
  );

  await resizeAndAck(ctx.tab, WIDE, 'prompt restored-wide');
  checkpoints.push(
    await capture(
      'restored-wide',
      'pending line back in one row, band re-anchored, no duplicated history rows and no stale narrow content — compare the recorded buffer',
      true,
    ),
  );

  await ctrl(ctx.tab, 'c');
  await waitScreen(
    ctx.tab,
    'prompt line cleared',
    (s) => s.screen.some((line) => /^prompt >\s*$/.test(line)),
    SOFT_MS,
  );
  checkpoints.push(
    await capture(
      'cleared',
      'ctrl+c cleared the whole pending line: the band row is exactly "prompt > " and the history above it is untouched',
    ),
  );

  await ctrl(ctx.tab, 'd');
  checkpoints.push(
    await exitShot(
      ctx,
      'prompt',
      ctx.marker,
      'ctrl+d quit: region.exit parked the cursor, caps.restore disabled the kitty keyboard, launcher printed rc=0',
    ),
  );
}

// ── scenario 3: REPL suggestion popup across a short terminal ─────────────
// "d" is source-confirmed multi-candidate: builtin_keywords IS the
// special_forms list (def, defn — skript_repl.zig:127-137) and the prelude
// adds display, disasm! and the dynamic-library:* bindings
// (vendor/skript/src/prelude.pt). The popup caps at max_rows = 8, so the band
// grows to 2 + shown rows.
async function replBody(ctx, checkpoints) {
  const bin = resolve(ctx.repoRoot, 'zig-out/bin', BIN.repl);
  const capture = (name, expected) => shot(ctx, 'repl', name, expected);
  await type(ctx.tab, launchApp(ctx, bin));
  await press(ctx.tab, 'Enter');
  const wide = await waitScreen(
    ctx.tab,
    'repl first frame',
    (s) => s.screen.some((line) => line.includes('Enter: eval')),
    FIRST_FRAME_MS,
    true,
  );

  await type(ctx.tab, 'd');
  await waitScreen(
    ctx.tab,
    'repl popup',
    (s) => s.screen.some((line) => line.includes('def')),
    SOFT_MS,
  );
  checkpoints.push(
    await capture(
      'popup-open',
      '2-row band plus popup rows under the token start: candidates sorted with the first selected, idle status row pushed down',
    ),
  );

  const short = shortViewport(wide);
  await resizeAndAck(ctx.tab, short, 'repl popup-short');
  checkpoints.push(
    await capture(
      'popup-short',
      `same width, ${short.height}px tall: the popup band and its candidate rows fit inside the ${SHORT_ROWS}-row terminal — the base band stays anchored and every shown candidate is legible, nothing clipped off the top`,
    ),
  );

  await resizeAndAck(ctx.tab, WIDE, 'repl popup-restored');
  checkpoints.push(
    await capture(
      'popup-restored',
      'full popup visible again after the height change, same candidate set and selection, no duplicated popup rows',
    ),
  );

  await press(ctx.tab, 'Escape');
  checkpoints.push(
    await capture(
      'popup-dismissed',
      'Esc collapses the popup and leaves the band at its 2-row base with the typed "d" intact: no candidate rows, no duplicated band row, and the dismissal holds until the next edit of the line',
    ),
  );

  await ctrl(ctx.tab, 'd');
  checkpoints.push(
    await exitShot(
      ctx,
      'repl',
      ctx.marker,
      'ctrl+d quit: no worker in flight, terminal restored, launcher printed rc=0',
    ),
  );
}

// ═══ temporal stress: the frames BETWEEN the checkpoints ═════════════════
//
// Every notui repaint lands in xterm.js, and ttyd publishes the real
// terminal as `window.term` in the PAGE MAIN WORLD — so hooking
// `window.term.onRender` there records each frame exactly as the app
// produced it: real cols/rows, real cursor, every screen row and every
// non-empty buffer row, in order, stamped with the label of the input that
// was in flight. Nothing here filters, judges, re-takes or settles: the
// half-drawn band between two refits is the defect this exists to keep.
//
// The tap is a page global, so it is read back THROUGH the page: the store
// is serialised to one JSON string in the main world and pulled out in
// chunks, because `tab.run`'s isolated world cannot see a page global and a
// multi-megabyte object straight through CDP is one enormous payload.
//
// xterm's `onRender` is an event SUBSCRIPTION, not an assignable slot:
// `term.onRender(listener)` returns a disposable. The tap subscribes
// through that API and disposes it on harvest, so no native event method
// is ever replaced and a second install cannot leak the first listener.
//
// Two bounds, kept apart because they mean different things. maxRenders
// caps how many frames are kept — past it the handler returns before it
// reads the buffer at all, so an over-long run cannot grow the payload
// pool either. maxBufferRows caps the non-empty buffer rows of ONE
// snapshot; hitting it is marked on that snapshot and counted. Either
// bound failing records itself and fails the scenario AFTER its
// artifacts are on disk: frames already observed are kept as they are,
// never re-taken and never quietly shortened.

/** The page-side install of the render tap. */
const tapInstallSource = (scenario, limits) => `(() => {
  const term = window.term;
  if (!term || !term.buffer || !term.buffer.active)
    return { ok: false, why: 'ttyd published no window.term in the page main world' };
  if (typeof term.onRender !== 'function')
    return { ok: false, why: 'window.term.onRender is not an event subscription' };
  const key = ${JSON.stringify(TAP.key)};
  const previous = window[key];
  if (previous && previous.subscription) previous.subscription.dispose();
  const store = {
    scenario: ${JSON.stringify(scenario)},
    maxRenders: ${limits.maxRenders},
    maxBufferRows: ${limits.maxBufferRows},
    stage: 'boot',
    t0: performance.now(),
    installedAt: Date.now(),
    entries: [],
    marks: [{ stage: 'boot', t: 0, renders: 0 }],
    pool: [],
    renderOverflow: false,
    renderDropped: 0,
    bufferOverflow: false,
    bufferDroppedRows: 0,
    bufferTruncatedSnapshots: 0,
    lastKey: null,
    lastPayload: -1,
    handler: null,
    subscription: null,
    json: null,
  };
  store.handler = () => {
    // The bound is checked FIRST: past maxRenders the handler returns
    // before it touches the buffer, so the payload pool cannot grow
    // either once the entry list is full.
    if (store.entries.length >= store.maxRenders) {
      store.renderOverflow = true;
      store.renderDropped += 1;
      return;
    }
    const t = Math.round(performance.now() - store.t0);
    const stage = store.stage;
    const buf = term.buffer.active;
    const text = (y) => {
      const line = buf.getLine(y);
      return line ? line.translateToString(true) : '';
    };
    const cols = term.cols;
    const rows = term.rows;
    const viewportY = buf.viewportY;
    const cursorX = buf.cursorX;
    const cursorY = buf.baseY + buf.cursorY - viewportY;
    // The REPL draws its cursor as a styled cell, not the hardware cursor.
    // Run-length encode every visible cell's attributes, including blanks.
    const screenAttrs = [];
    const cell = buf.getNullCell();
    for (let y = viewportY; y < viewportY + rows; y++) {
      const line = buf.getLine(y);
      const runs = [];
      let previous = null;
      for (let x = 0; x < cols; x++) {
        const c = line?.getCell(x, cell);
        const flags = c ? Number(!!c.isBold()) |
          (Number(!!c.isDim()) << 1) | (Number(!!c.isItalic()) << 2) |
          (Number(!!c.isUnderline()) << 3) | (Number(!!c.isBlink()) << 4) |
          (Number(!!c.isInverse()) << 5) | (Number(!!c.isInvisible()) << 6) |
          (Number(!!c.isStrikethrough()) << 7) | (Number(!!c.isOverline()) << 8) : null;
        const attrs = c
          ? [c.getFgColorMode(), c.getFgColor(), c.getBgColorMode(), c.getBgColor(), flags]
          : [null, null, null, null, null];
        const signature = attrs.join(',');
        if (signature === previous) {
          runs[runs.length - 1][1]++;
        } else {
          runs.push([x, 1, ...attrs]);
          previous = signature;
        }
      }
      screenAttrs.push(runs);
    }
    const screen = [];
    for (let y = viewportY; y < viewportY + rows; y++) screen.push(text(y));
    const all = [];
    for (let y = 0; y < buf.length; y++) {
      const row = text(y);
      if (row.trim()) all.push(row);
    }
    const bufferTotal = all.length;
    const cut =
      bufferTotal > store.maxBufferRows ? bufferTotal - store.maxBufferRows : 0;
    const buffer = cut ? all.slice(cut) : all;
    if (cut) {
      store.bufferOverflow = true;
      store.bufferDroppedRows += cut;
      store.bufferTruncatedSnapshots += 1;
    }
    const key =
      [cols, rows, viewportY, cursorX, cursorY,
       screen.join('\\u0000'), buffer.join('\\u0000'), JSON.stringify(screenAttrs)].join('\\u0001');
    const entry = { t, stage, cols, rows, cursorX, cursorY };
    if (key === store.lastKey) {
      entry.same = store.lastPayload;
    } else {
      store.pool.push({
        viewportY,
        baseY: buf.baseY,
        length: buf.length,
        bufferTotal,
        bufferKept: buffer.length,
        bufferDropped: cut,
        screen,
        screenAttrs,
        buffer,
      });
      store.lastKey = key;
      store.lastPayload = store.pool.length - 1;
      entry.p = store.lastPayload;
    }
    store.entries.push(entry);
  };
  store.subscription = term.onRender(store.handler);
  window[key] = store;
  return { ok: true, cols: term.cols, rows: term.rows };
})()`;

/** Unsubscribe, serialise, and report the counts the run has to be judged by. */
const TAP_HARVEST = `(() => {
  const store = window.${TAP.key};
  if (!store) return { ok: false, why: 'the render tap was never installed' };
  if (store.subscription) {
    store.subscription.dispose();
    store.subscription = null;
  }
  store.json = JSON.stringify({
    installedAt: store.installedAt,
    harvestedAt: Date.now(),
    renderOverflow: store.renderOverflow,
    renderDropped: store.renderDropped,
    bufferOverflow: store.bufferOverflow,
    bufferDroppedRows: store.bufferDroppedRows,
    bufferTruncatedSnapshots: store.bufferTruncatedSnapshots,
    marks: store.marks,
    entries: store.entries,
    pool: store.pool,
  });
  return {
    ok: true,
    length: store.json.length,
    entries: store.entries.length,
    payloads: store.pool.length,
    renderOverflow: store.renderOverflow,
    renderDropped: store.renderDropped,
    bufferOverflow: store.bufferOverflow,
    bufferDroppedRows: store.bufferDroppedRows,
    bufferTruncatedSnapshots: store.bufferTruncatedSnapshots,
    maxRenders: store.maxRenders,
    maxBufferRows: store.maxBufferRows,
  };
})()`;

const TAP_CLEAR = `(() => {
  const store = window.${TAP.key};
  if (!store) return false;
  if (store.subscription) {
    store.subscription.dispose();
    store.subscription = null;
  }
  store.json = null;
  window.${TAP.key} = undefined;
  return true;
})()`;

/** Label the input in flight; paints may coalesce across multiple inputs. */
const markStage = (ctx, label) =>
  ctx.tab.evaluate(`(() => {
    const s = window.${TAP.key};
    if (!s) return false;
    s.stage = ${JSON.stringify(label)};
    s.marks.push({ stage: s.stage, t: Math.round(performance.now() - s.t0), renders: s.entries.length });
    return true;
  })()`);

/** Where the render tap currently is, so a PNG can name its frame index. */
const tapMark = (ctx) =>
  ctx.tab.evaluate(`(() => {
    const s = window.${TAP.key};
    if (!s) return null;
    return {
      renders: s.entries.length,
      renderDropped: s.renderDropped,
      bufferDroppedRows: s.bufferDroppedRows,
      t: Math.round(performance.now() - s.t0),
      stage: s.stage,
    };
  })()`);

/**
 * A settled final surface: `shot` writes the PNG, and the checkpoint also
 * carries the tap's entry index so the parent can read the exact frames
 * either side of it in the timeline.
 */
async function temporalShot(ctx, scenario, name, invariant, withBuffer = false) {
  const checkpoint = await shot(ctx, scenario, name, invariant, withBuffer);
  const mark = await tapMark(ctx);
  if (!mark) return checkpoint;
  return {
    ...checkpoint,
    timeline: {
      file: ctx.timelineFile,
      video: ctx.video,
      stage: mark.stage,
      t: mark.t,
      renders: mark.renders,
      renderDropped: mark.renderDropped,
      bufferDroppedRows: mark.bufferDroppedRows,
    },
  };
}

/** Observed render counts per in-flight stage; zero-render stages remain visible. */
function stageIndex(entries, marks) {
  const counts = new Map();
  const firstAt = new Map();
  entries.forEach((entry, at) => {
    counts.set(entry.stage, (counts.get(entry.stage) ?? 0) + 1);
    if (!firstAt.has(entry.stage)) firstAt.set(entry.stage, at);
  });
  for (const { stage } of marks) {
    if (!counts.has(stage)) counts.set(stage, 0);
  }
  return [...counts].map(([stage, renders]) => ({
    stage,
    renders,
    first: firstAt.get(stage) ?? null,
  }));
}

async function tapStart(tab, scenario, limits) {
  const started = await tab.evaluate(tapInstallSource(scenario, limits));
  if (!started?.ok)
    throw new Error(
      `[temporal] ${scenario}: render tap not installed — ${started?.why ?? 'the page answered nothing'}`,
    );
  return started;
}

/** Pull the store out of the page, write it, and summarise it for the parent. */
async function tapStop(tab, meta) {
  const info = await tab.evaluate(TAP_HARVEST);
  if (!info?.ok)
    throw new Error(`[temporal] ${meta.scenario}: ${info?.why ?? 'the tap vanished'}`);
  let raw = '';
  for (let at = 0; at < info.length; at += TAP.pullChunk) {
    const end = Math.min(at + TAP.pullChunk, info.length);
    raw += await tab.evaluate(`window.${TAP.key}.json.slice(${at}, ${end})`);
  }
  await tab.evaluate(TAP_CLEAR);
  const tap = JSON.parse(raw);
  const file = resolve(
    meta.outputDir,
    `temporal-${meta.scenario}-timeline.json`,
  );
  await writeFile(
    file,
    JSON.stringify({
      scenario: meta.scenario,
      baseUrl: meta.baseUrl,
      video: meta.video,
      nativeCapacity: meta.capacity ?? null,
      launchCommands: meta.commands ?? [],
      maxRenders: info.maxRenders,
      maxBufferRows: info.maxBufferRows,
      installedAt: tap.installedAt,
      harvestedAt: tap.harvestedAt,
      stageMeaning: 'input in flight at render time; not key-to-paint causality',
      styleRunFields: ['column', 'length', 'fgMode', 'fg', 'bgMode', 'bg', 'flags'],
      styleFlagBits: ['bold', 'dim', 'italic', 'underline', 'blink', 'inverse',
        'invisible', 'strikethrough', 'overline'],
      marks: tap.marks,
      renderOverflow: tap.renderOverflow,
      renderDropped: tap.renderDropped,
      bufferOverflow: tap.bufferOverflow,
      bufferDroppedRows: tap.bufferDroppedRows,
      bufferTruncatedSnapshots: tap.bufferTruncatedSnapshots,
      entries: tap.entries,
      pool: tap.pool,
    }),
  );
  return {
    scenario: meta.scenario,
    file,
    video: meta.video,
    nativeCapacity: meta.capacity ?? null,
    launchCommands: meta.commands ?? [],
    renders: info.entries,
    payloads: info.payloads,
    renderOverflow: info.renderOverflow,
    renderDropped: info.renderDropped,
    bufferOverflow: info.bufferOverflow,
    bufferDroppedRows: info.bufferDroppedRows,
    bufferTruncatedSnapshots: info.bufferTruncatedSnapshots,
    maxRenders: info.maxRenders,
    maxBufferRows: info.maxBufferRows,
    installedAt: tap.installedAt,
    harvestedAt: tap.harvestedAt,
    stages: stageIndex(tap.entries, tap.marks),
  };
}

// ── temporal scenario 1: statusline animation across 3 wide/narrow cycles ─
// A unique pre-app marker printed by bash is the reference for "which rows
// existed before any notui frame"; the gauge is redrawn every tick, so two
// settled shots at one geometry show the animation really moved; three
// wide→narrow→wide cycles put the same refit under the band three times.
async function statuslineTemporalBody(ctx, checkpoints) {
  const bin = resolve(ctx.repoRoot, 'zig-out/bin', BIN.statusline);
  const { tab } = ctx;
  const capture = (name, invariant, withBuffer) =>
    temporalShot(ctx, 'statusline', name, invariant, withBuffer);
  const mark = (label) => markStage(ctx, `statusline/${label}`);

  await mark('preapp/marker');
  await type(
    tab,
    `export PS1=''; printf '\\e[H\\e[2J\\e[3J'; printf '%s\\n' ${ctx.preapp.map(shq).join(' ')}`,
  );
  await press(tab, 'Enter');
  await waitScreen(
    tab,
    'statusline preapp marker',
    (s) => s.screen.some((line) => line.includes(ctx.preapp[0])),
    FIRST_FRAME_MS,
    true,
  );
  checkpoints.push(
    await capture(
      'preapp-marker',
      `two bash-printed marker rows on a cleared terminal (${ctx.preapp.join(' / ')}), before any notui frame — every later refit must leave both intact, and the recorded buffer shows exactly where they sit`,
      true,
    ),
  );

  await mark('launch');
  await type(tab, launchApp(ctx, bin));
  await press(tab, 'Enter');
  await waitScreen(
    tab,
    'statusline first frame',
    (s) => s.screen.some((line) => /NORMAL|v\d+\.\d+\.\d+/.test(line)),
    FIRST_FRAME_MS,
    true,
  );
  checkpoints.push(
    await capture(
      'anim-a',
      'first settled wide frame: the 3-row band is contiguous, the right tail reports the real column count, and the pre-app marker rows sit untouched above it',
    ),
  );

  await mark('animate/wait');
  await sleep(ctx.animationMs);
  checkpoints.push(
    await capture(
      'anim-b',
      `same geometry as anim-a, ${ctx.animationMs}ms later: the gauge's fill and percent have ADVANCED while nothing was typed — the still frames of both are in the video and the gauge frames are in the timeline`,
    ),
  );

  for (let cycle = 1; cycle <= 3; cycle++) {
    await mark(`resize/c${cycle}/narrow`);
    await resizeAndAck(tab, NARROW, `statusline c${cycle} narrow`);
    await sleep(200); // Keep an animation tick in every refit dwell.
    if (cycle === 1)
      checkpoints.push(
        await capture(
          'cycle-1-narrow',
          'first narrow refit: the band redraws at the narrow width with no stale wide row surviving it; the pre-app marker rows must still be whole, and the narrow cols go in the record',
        ),
      );
    await mark(`resize/c${cycle}/wide`);
    await resizeAndAck(tab, WIDE, `statusline c${cycle} wide`);
    await sleep(200);
  }
  checkpoints.push(
    await capture(
      'cycle-3-wide',
      'back at the wide geometry after three wide→narrow→wide cycles: the band matches anim-a/anim-b in layout, the marker rows are still exactly where they were, and no refit duplicated a committed row',
      true,
    ),
  );

  await mark('exit/q');
  await press(tab, 'q');
  checkpoints.push(
    await exitShot(
      ctx,
      'statusline',
      ctx.marker,
      'q quit: the cursor parks below the band, the terminal is restored and the launcher printed rc=0 — the frames between the last band and the marker are in the timeline',
    ),
  );
}

// ── temporal scenario 2: REPL under fast keys, popup churn and refits ────
// Every wait past the first frame is SOFT: the app's exact band height and
// popup contents are what this run is measuring, so it never gates on them.
async function replTemporalBody(ctx, checkpoints) {
  const bin = resolve(ctx.repoRoot, 'zig-out/bin', BIN.repl);
  const { tab } = ctx;
  const gap = ctx.keyGapMs;
  const capture = (name, invariant, withBuffer) =>
    temporalShot(ctx, 'repl', name, invariant, withBuffer);
  const mark = (label) => markStage(ctx, `repl/${label}`);

  await mark('launch');
  await type(tab, launchApp(ctx, bin));
  await press(tab, 'Enter');
  await waitScreen(
    tab,
    'repl first frame',
    (s) => s.screen.some((line) => /^\s*skript>|skript repl/.test(line)),
    FIRST_FRAME_MS,
    true,
  );

  // Rapid midline edits: type the form, then cycle left-4 → insert "1" →
  // Backspace, each key 10-20ms behind the last, so the band is redrawn
  // between every keystroke. The line must come back byte-identical.
  await mark('midline/type-form');
  await typeAt(tab, REPL_FORM, gap);
  for (let cycle = 1; cycle <= ctx.midlineCycles; cycle++) {
    await mark(`midline/c${cycle}/end`);
    await press(tab, 'End');
    await mark(`midline/c${cycle}/left4`);
    await pressSpaced(tab, gap, [
      'ArrowLeft',
      'ArrowLeft',
      'ArrowLeft',
      'ArrowLeft',
    ]);
    await mark(`midline/c${cycle}/insert-1`);
    await typeAt(tab, '1', gap);
    await mark(`midline/c${cycle}/backspace`);
    await pressSpaced(tab, gap, ['Backspace']);
  }
  checkpoints.push(
    await capture(
      'midline-cycled',
      `after ${ctx.midlineCycles} left-4/insert-1/Backspace cycles at ${KEY_GAP_MIN_MS}-${KEY_GAP_MAX_MS}ms key spacing the input row reads "${REPL_FORM}" again with the cursor mid-line: one prompt row, nothing left from an interrupted repaint, no duplicated or half-erased row — every intermediate frame is in the timeline, including the ones that were wrong for a frame or two`,
      true,
    ),
  );

  // Cursor motion across the whole line (Home, Right×4, Left×6 to clamp at
  // column 0, End) and then the ctrl chords for the same two ends.
  await mark('motion/home-right-left-end');
  await pressSpaced(tab, gap, [
    'Home',
    'ArrowRight',
    'ArrowRight',
    'ArrowRight',
    'ArrowRight',
    'ArrowLeft',
    'ArrowLeft',
    'ArrowLeft',
    'ArrowLeft',
    'ArrowLeft',
    'ArrowLeft',
    'End',
  ]);
  await mark('motion/ctrl-a');
  await ctrl(tab, 'a');
  await mark('motion/ctrl-e');
  await ctrl(tab, 'e');
  await mark('motion/clear-ctrl-c');
  await ctrl(tab, 'c');
  await waitScreen(
    tab,
    'repl line cleared',
    (s) => s.screen.some((line) => /^skript>\s*$/.test(line)),
    SOFT_MS,
  );
  checkpoints.push(
    await capture(
      'cleared',
      '^C emptied the line: the only surviving row is the bare prompt, no popup, and no cell left over from the edit cycles or the cursor sweep — everything above it is untouched',
    ),
  );

  // Popup churn: open on a prefix, navigate the candidates, dismiss with
  // Escape, then edit the line so the popup re-opens.
  await mark('popup/type-d');
  await typeAt(tab, 'd', gap);
  await waitScreen(
    tab,
    'repl popup open',
    (s) => s.screen.some((line) => /^\s*skript> d\s*$/.test(line)),
    SOFT_MS,
  );
  await mark('popup/navigate');
  await pressSpaced(tab, gap, ['ArrowDown', 'ArrowDown']);
  await mark('popup/escape');
  await press(tab, 'Escape');
  await mark('popup/reopen-edit');
  await pressSpaced(tab, gap, ['Backspace']);
  await mark('popup/reopen-type-d');
  await typeAt(tab, 'd', gap);
  await waitScreen(
    tab,
    'repl popup reopened',
    (s) => s.screen.some((line) => /^\s*skript> d\s*$/.test(line)),
    SOFT_MS,
  );
  checkpoints.push(
    await capture(
      'popup-reopen',
      'the popup after Escape + an edit: candidates are visible again under the token, the selection is back at the first entry, the band grew and shrank through the cycle without leaving a stale candidate row — the dismissed and re-opened intermediate bands are in the timeline',
    ),
  );

  // Movement across a quoted, multibyte form: no candidate may open inside
  // the strings, and no cursor may land mid-codepoint.
  await mark('quote/clear');
  await ctrl(tab, 'c');
  await mark('quote/type');
  await typeAt(tab, REPL_QUOTED, gap);
  await mark('quote/motion-right');
  await pressSpaced(tab, gap, ['Home', ...Array.from(REPL_QUOTED, () => 'ArrowRight')]);
  await mark('quote/motion-left');
  await pressSpaced(tab, gap, Array.from(REPL_QUOTED, () => 'ArrowLeft'));
  await press(tab, 'End');
  await mark('quote/ctrl-a');
  await ctrl(tab, 'a');
  await mark('quote/ctrl-e');
  await ctrl(tab, 'e');

  // The popup in a 6-row terminal, at the SHORT geometry measured from the
  // live page — never a hard-coded height.
  await mark('popup/clear-for-short');
  await ctrl(tab, 'c');
  await mark('popup/type-d-for-short');
  await typeAt(tab, 'd', gap);
  const live = await readState(tab);
  const short = shortViewport(live);
  await mark('resize/short');
  const shortState = await resizeAndAck(tab, short, 'repl popup-short');
  checkpoints.push(
    await capture(
      'popup-short',
      `the popup open at the short geometry measured from this page (${short.width}x${short.height} asked for; the terminal really refitted to ${shortState.cols}x${shortState.rows}, those are the numbers to judge): the base band and the candidate rows share the short screen, and the timeline holds the refit frames where the band was still the tall one`,
    ),
  );
  if (shortState.rows !== SHORT_ROWS) {
    throw new Error(`[temporal] popup-short requested ${SHORT_ROWS} rows, got ${shortState.rows}; PNG saved`);
  }

  // Repeated width AND height cycles, three times each way.
  for (let cycle = 1; cycle <= 3; cycle++) {
    await mark(`resize/c${cycle}/wide`);
    await resizeAndAck(tab, WIDE, `repl c${cycle} wide`);
    await mark(`resize/c${cycle}/narrow`);
    await resizeAndAck(tab, NARROW, `repl c${cycle} narrow`);
    await mark(`resize/c${cycle}/short`);
    await resizeAndAck(tab, short, `repl c${cycle} short`);
  }
  await mark('resize/final-wide');
  await resizeAndAck(tab, WIDE, 'repl final wide');

  // Two real evals — one single-line (⇒ 42), one continued across two rows
  // (⇒ 60) — then a history recall of each.
  await mark('eval/clear');
  await ctrl(tab, 'c');
  await mark('eval/type-42');
  await typeAt(tab, REPL_FORM, gap);
  await press(tab, 'Enter');
  await waitScreen(
    tab,
    'repl answer 42',
    (s) => s.screen.some((line) => /⇒\s*42\b/.test(line)),
    SOFT_MS,
  );
  await mark('eval/type-60-open');
  await typeAt(tab, REPL_OPEN_FORM, gap);
  await mark('eval/remove-auto-close');
  await press(tab, 'Delete');
  await press(tab, 'Enter');
  await mark('eval/type-60-close');
  await typeAt(tab, REPL_CLOSE_FORM, gap);
  await press(tab, 'Enter');
  await waitScreen(
    tab,
    'repl answer 60',
    (s) => s.screen.some((line) => /⇒\s*60\b/.test(line)),
    SOFT_MS,
  );
  await mark('eval/history-up');
  await pressSpaced(tab, gap, ['ArrowUp']);
  await mark('eval/history-down');
  await pressSpaced(tab, gap, ['ArrowDown']);
  checkpoints.push(
    await capture(
      'evaluated',
      `both answers committed above the band — "${REPL_FORM}" ⇒ 42 and the two-row "${REPL_OPEN_FORM} ${REPL_CLOSE_FORM}" ⇒ 60, each exactly once, oldest in scrollback — and the history key brought the multiline query back onto the input row without disturbing either answer; count them in the recorded buffer`,
      true,
    ),
  );

  await mark('exit/ctrl-d');
  await ctrl(tab, 'd');
  checkpoints.push(
    await exitShot(
      ctx,
      'repl',
      ctx.marker,
      '^D quit: the band is restored, both answers stay in scrollback and the launcher printed rc=0 — the frames from the last key to the marker are in the timeline',
    ),
  );
}

/**
 * One temporal scenario: recording and render tap ON before the app is
 * launched, then evidence FIRST in the teardown. A live failure (a missing
 * or non-zero exit) is re-thrown only after the PNG, the timeline JSON and
 * the video are all on disk, and a teardown failure never masks it.
 */
async function runTemporalScenario(ctx, name, body, checkpoints) {
  const tab = await openScenarioTab(ctx, name);
  const video = resolve(ctx.outputDir, `temporal-${name}.webm`);
  const scenarioCtx = {
    ...ctx,
    tab,
    scenario: name,
    recipe: 'temporal',
    marker: `TEMPORAL-${name.toUpperCase()}`,
    video,
    capacity: null,
    commands: [],
    timelineFile: resolve(ctx.outputDir, `temporal-${name}-timeline.json`),
  };
  const local = [];
  let bodyErr = null;
  let recordErr = null;
  let tapErr = null;
  let summary = null;
  try {
    await resize(tab, WIDE);
    const booted = await waitScreen(
      tab,
      'ttyd terminal boot',
      (s) => s.cols > 0 && s.rows > 0,
      FIRST_FRAME_MS,
      true,
    );
    // This tab's own scrollback is the declared native retention capacity
    // the region app launched in it is told about.
    await declareCapacity(scenarioCtx, booted, 'temporal');
    await focusTerminal(tab);
    try {
      await tab.recordStart(video);
    } catch (err) {
      // The frames and the PNGs still stand on their own, but a scenario
      // that could not record has not done what it was asked to do.
      recordErr = err;
    }
    await tapStart(tab, name, ctx.tap);
    await body(scenarioCtx, local);
  } catch (err) {
    bodyErr = err;
  } finally {
    try {
      summary = await tapStop(tab, {
        scenario: name,
        baseUrl: ctx.baseUrl,
        outputDir: ctx.outputDir,
        video,
        capacity: scenarioCtx.capacity,
        commands: [...scenarioCtx.commands],
      });
    } catch (err) {
      tapErr = err;
    }
    if (!recordErr) {
      try {
        await tab.run(async ({ tab }) => tab.recordStop(), { timeout: 180 });
      } catch (err) {
        recordErr = err;
      }
    }
    try {
      await tab.close();
    } catch {}
  }
  checkpoints.push(...local);
  if (bodyErr) throw bodyErr;
  if (tapErr) throw tapErr;
  if (!summary || summary.renders === 0)
    throw new Error(`[temporal] ${name}: no render events recorded; evidence saved to ${scenarioCtx.timelineFile}`);
  if (summary?.renderOverflow)
    throw new Error(
      `[temporal] ${name}: the render tap passed its ${summary.maxRenders}-render bound; ${summary.renderDropped} render(s) past that point were not captured, AFTER the first ${summary.renders} were written to ${summary.file}`,
    );
  if (summary?.bufferOverflow)
    throw new Error(
      `[temporal] ${name}: ${summary.bufferTruncatedSnapshots} snapshot(s) had more than ${summary.maxBufferRows} non-empty buffer rows; ${summary.bufferDroppedRows} oldest buffer row(s) were not recorded — every truncated snapshot carries its own bufferTotal/bufferKept/bufferDropped in ${summary.file}`,
    );
  if (recordErr) throw recordErr;
  return { ...summary, capacity: scenarioCtx.capacity, commands: [...scenarioCtx.commands] };
}

/**
 * Run the temporal scenarios and return what to read: the PNG checkpoints,
 * the per-scenario timeline/video paths with their render counts and the
 * per-input stage index, plus a temporal-report.json manifest. One ttyd tab
 * per scenario, released in the scenario's own finally.
 */
export async function runTemporalStress(browser, options) {
  const {
    baseUrl,
    outputDir,
    app,
    repoRoot = process.cwd(),
    scenarios = ['statusline', 'repl'],
    maxRenders = TAP.maxRenders,
    maxBufferRows = TAP.maxBufferRows,
    keyGapMs = KEY_GAP_MIN_MS,
    midlineCycles = MIDLINE_CYCLES,
    animationMs = ANIMATION_MS,
  } = options;
  const dir = resolve(outputDir);
  await mkdir(dir, { recursive: true });
  const stamp = Date.now().toString(36).toUpperCase();
  const ctx = {
    browser,
    baseUrl,
    outputDir: dir,
    app,
    repoRoot,
    host: new URL(baseUrl).hostname,
    pngPrefix: 'temporal',
    tabPrefix: 'temporal',
    tap: {
      maxRenders: bound(maxRenders, TAP.maxRenders),
      maxBufferRows: bound(maxBufferRows, TAP.maxBufferRows),
    },
    keyGapMs,
    midlineCycles: bound(midlineCycles, MIDLINE_CYCLES),
    animationMs: bound(animationMs, ANIMATION_MS),
    // Run-unique so the pre-app rows cannot be confused with any earlier
    // capture's history; reported verbatim so the parent can find them.
    preapp: [`VTMP-PREAPP-${stamp}`, `VTMP-PREAPP-${stamp}-B`],
  };
  const bodies = { statusline: statuslineTemporalBody, repl: replTemporalBody };
  for (const name of scenarios) {
    if (!bodies[name])
      throw new Error(
        `[temporal] unknown scenario '${name}' — pick from ${Object.keys(bodies).join(' / ')}`,
      );
  }
  const checkpoints = [];
  const timelines = [];
  // A failed scenario has already saved its PNG, its timeline and its
  // video; the manifest is written either way so the parent can still find
  // every artifact, and only then does the failure propagate.
  let failed = null;
  try {
    for (const name of scenarios)
      timelines.push(
        await runTemporalScenario(ctx, name, bodies[name], checkpoints),
      );
  } catch (err) {
    failed = err;
  }
  const report = resolve(dir, 'temporal-report.json');
  await writeFile(
    report,
    JSON.stringify(
      {
        baseUrl,
        outputDir: dir,
        wide: WIDE,
        narrow: NARROW,
        nativeCapacity: {
          flag: CAPACITY_FLAG,
          meaning:
            'every region app this recipe launches (the statusline and the REPL) carries --terminal-scrollback-rows=N with N read from THAT tab\'s own window.term.options.scrollback, never from a constant of this driver: the examples build Region.TerminalReflow .{.non_cursor_rows=.{.scrollback_rows=N}} from it and stay .none without it. Per-scenario values and the exact commands are in timelines[].nativeCapacity / timelines[].launchCommands.',
          perScenario: Object.fromEntries(
            timelines.map((t) => [t.scenario, t.nativeCapacity ?? null]),
          ),
        },
        error: failed ? String(failed) : null,
        checkpoints,
        timelines,
      },
      null,
      2,
    ),
  );
  if (failed) throw failed;
  return { baseUrl, outputDir: dir, wide: WIDE, narrow: NARROW, report, checkpoints, timelines };
}

/**
 * Run the three live-resize scenarios and return plain metadata. One ttyd
 * tab per scenario, released in `finally`.
 */
export async function runResizeStress(browser, options) {
  const { baseUrl, outputDir, app, repoRoot = process.cwd() } = options;
  const dir = resolve(outputDir);
  await mkdir(dir, { recursive: true });
  const ctx = { browser, baseUrl, outputDir: dir, app, repoRoot, host: new URL(baseUrl).hostname };
  const checkpoints = [];
  const scenarios = {};
  const bodies = { statusline: statuslineBody, prompt: promptBody, repl: replBody };
  for (const [name, body] of Object.entries(bodies)) {
    const run = await runScenario(ctx, name, body);
    checkpoints.push(...run.checkpoints);
    scenarios[name] = { capacity: run.capacity, commands: run.commands };
  }
  return { baseUrl, outputDir: dir, wide: WIDE, narrow: NARROW, checkpoints, scenarios };
}

// ═══ ownership resize stress: WHO OWNS WHICH ROW ════════════════════════
//
// Both open defects live in the same place: rows the region owned before a
// geometry change and does not own after it. Growing a band back from one
// row to the full terminal height repaints the live group lower and can
// leave the pre-shrink group on screen above it — its input row, its own
// inverse-highlighted candidate, everything still looking selected. A width
// change reflows the very same owned rows: a hard row wider than the narrow
// terminal genuinely splits into several rows there and merges back when
// the width returns, so the app can read a row it no longer owns, or skip
// the one it does. Every geometry this recipe asserts is derived from the
// live page and recorded as measured — no cols/rows figure is pinned here,
// because the fitted size of a viewport is not a constant of this driver.
//
// Nothing here decides WHICH prompt row is live. Every checkpoint records
// the whole bounded buffer with each row's wrap flag, used cells and
// inverse runs, and the driver groups the rows structurally: the band's own
// first row plus the rows directly under it. The bottom-most group the
// terminal is SHOWING is the live band (a region anchors at the terminal's
// bottom), and a group above it is residue while it is still on screen —
// reported with its own input text, candidates and selection instead of
// being argued away, and recorded as archived either way once the terminal
// scrolls past it — scrolling one out of view does not commit it. The 36
// committed marker rows printed by bash BEFORE the app ever ran are
// the reference for "committed history, still committed": each must appear
// exactly once, so a dropped or duplicated row cannot hide inside the band.
//
// The recipe is bounded and single-purpose. Every failure lands in the
// report — and every PNG on disk — before anything is thrown.
const OWN = Object.freeze({
  markers: 36,
  maxBufferRows: 512,
  phases: ['before', 'after'],
  // The REPL's own strings (examples/skript_repl.zig: prompt_text,
  // idle_status; the band is input + status + at most max_rows candidates).
  prompt: 'skript>',
  status: 'Enter: eval',
  // The statusline's own strings: the badge, the gauge label, the wrapped
  // message and the right tail that reports the width the app believes it
  // has.
  badge: ' NORMAL ',
  gauge: 'scan',
  message: 'the quick brown fox',
});

// ── the mixed ASCII + width-two glyph input the `mix` scenario types ─────
// One 129-column hard row: 47 ASCII columns and 37 width-two glyphs make
// a 121-column body; the REPL's 8-column prompt ('skript> ') makes 129.
// The wide checkpoint requires it to fit. The odd narrow checkpoint proves
// the terminal's native split of the retired source.
//
// The REPL paints that line as ONE row and never wraps it: drawBand draws
// prompt + active line at row 0, and Buffer.draw CLIPS (src/buffer.zig — a
// wide glyph that would cross the right edge drops, and with it the rest of
// the line). So at a narrow width the app's own input row is the grapheme
// PREFIX that fits the measured columns — the whole 129-column line exists
// again only as the TERMINAL's own reflow of the hard row the app retired,
// which is exactly what this recipe asserts (`nativeWrapOf`), because that
// reflow is the only proof the wide source really survives. The ASCII run
// holds no space and ends in a letter, so no split boundary can trim real
// content and no typed run can read as a shell echo.
const MIX_ASCII = 'own-mix-ascii-47-cols-and-37-wide-glyphs-abcdef';
const MIX_GLYPH = '界'; // one width-two column pair
const MIX_GLYPHS = 37;
// The physical height the band is clipped INTO. The band is two rows —
// input + status — and bandHeight(1, 0) is 1 (examples/skript_repl.zig): a
// 1-row terminal keeps the INPUT row alone and the status row has nowhere
// to go. The clip therefore RETIRES the band's old first input row (it
// scrolls out of the 1-row viewport with the status row) and the app
// repaints the same whole line on the surviving row, before any narrowing
// happens; every later step runs at that one row, where the app holds a
// prefix of the line and the wide source survives only as the terminal's
// own reflow of the row the clip retired.
const MIX_CLIP_ROWS = 1;
const MIX = Object.freeze({
  ascii: MIX_ASCII,
  glyph: MIX_GLYPH,
  glyphs: MIX_GLYPHS,
  clipRows: MIX_CLIP_ROWS,
  // The prompt is `skript> ` — the trailing space is one of the 8 columns.
  text: MIX_ASCII + MIX_GLYPH.repeat(MIX_GLYPHS),
  columns: `${OWN.prompt} `.length + MIX_ASCII.length + 2 * MIX_GLYPHS,
});

// The declared native scrollback capacity every ownership launch carries.
// The examples build `.{ .non_cursor_rows = .{ .scrollback_rows = N } }`
// from this argument and fall back to `.none` when it is absent, so this
// argument is what puts native reflow on at all — and N must be the
// scrollback the LIVE terminal really has, read per tab, never a constant
// of this driver.
const CAPACITY_FLAG = '--terminal-scrollback-rows=';

const RE_INPUT = /^\s*skript>/;
const RE_CANDIDATE = /^\s+\S/;
const RE_STATUS = /^Enter: eval/;
const SL_BADGE = / NORMAL /;
const RE_TAIL = /col (\d+)\s*$/;
// A bare shell prompt and nothing else: a word ending in a prompt sigil
// ('Apptainer>', '$', '#') with no payload behind it. 'def' is not one.
const PROMPT_ROW = /^\S*[$#%>] *$/;

/** `OWN-01`..`OWN-36`: short, distinct, and none a substring of another. */
const markerSet = (n = OWN.markers) =>
  Array.from({ length: n }, (_, i) => `OWN-${String(i + 1).padStart(2, '0')}`);

/**
 * The bash that prints the marker rows: a cleared screen AND scrollback
 * first, so nothing of the ttyd session is in the way, then one committed
 * row per marker. The loop text itself never spells a marker out, so the
 * shell's own echo of this command can never be counted as one.
 */
const markerCommand = (n = OWN.markers) =>
  `export PS1=''; printf '\\e[H\\e[2J\\e[3J'; i=1; while [ $i -le ${n} ]; do printf 'OWN-%02d\\n' "$i"; i=$((i+1)); done`;

/**
 * Is this buffered row a fragment of a command THIS driver typed? A long
 * command is echoed wrapped across rows and behind a shell prompt, so each
 * of its rows is a contiguous fragment of the command text, possibly with
 * a prompt token in front of it — which is what keeps a long loader prefix
 * (an argv wrapped over several rows) from reading as unowned content.
 *
 * Nothing else counts. A single word with nothing behind it is NOT a shell
 * echo: an empty remainder behind a stripped token only proves the row was
 * one word long, and treating that as echoed content would swallow band
 * rows like 'def' or 'deg->rad' and hide the very residue this recipe
 * exists to find. The one bare row a shell does leave is a prompt, and
 * PROMPT_ROW is that shape and nothing else.
 */
const isTypedEcho = (text, commands) => {
  const row = text.trim();
  if (row === '') return true;
  if (commands.some((cmd) => cmd.includes(row))) return true;
  // The wrapped first row of an echo starts with the shell's prompt.
  const afterPrompt = row.replace(/^\S*\s?/, '');
  if (afterPrompt !== '' && commands.some((cmd) => cmd.includes(afterPrompt))) return true;
  return PROMPT_ROW.test(row);
};

/**
 * This run's own launcher's exit line: the marker it was launched with, and
 * a NUMERIC rc. Anchored at both ends, so the echoed launch command can
 * never satisfy it and a row of the app's own text can never be mistaken
 * for it. One definition, shared by the row classifier and the exit checks.
 */
const exitPattern = (ctx) => new RegExp(`^VISUAL_EXIT ${ctx.marker} rc=\\d+$`);

/**
 * What was actually launched: the path as typed, the file behind it, its
 * size and the SHA-256 of its bytes. A path and a label cannot tell two
 * rebuilds of the same example apart; the hash can, and it is the only
 * thing in the report that identifies the build under test.
 */
async function binaryIdentity(binAbs) {
  let bytes;
  let st;
  let real;
  try {
    [bytes, st, real] = await Promise.all([
      readFile(binAbs),
      stat(binAbs),
      realpath(binAbs),
    ]);
  } catch (err) {
    throw new Error(`[ownership] cannot read the binary to launch (${binAbs}): ${err}`);
  }
  return {
    path: binAbs,
    realpath: real,
    bytes: st.size,
    sha256: createHash('sha256').update(bytes).digest('hex'),
  };
}

/**
 * The scrollback the LIVE terminal really has, read from ttyd's
 * `window.term.options.scrollback` in the PAGE MAIN WORLD — one read per
 * tab, because each scenario is a fresh pty with its own terminal.
 *
 * This number is the DECLARED native retention capacity the app is
 * launched with: it is what the examples turn into
 * `.{ .non_cursor_rows = .{ .scrollback_rows = N } }`, and without the
 * argument they run `.none`, i.e. no native reflow at all. A constant of
 * this driver would be a lie about the terminal under test, so an
 * unusable read is a hard failure here rather than a fallback number.
 */
const readCapacity = (tab) =>
  tab.evaluate(`(() => {
    const term = window.term;
    if (!term || !term.options) return { ready: false, why: 'no window.term in the page main world' };
    const raw = term.options.scrollback;
    const n = Number(raw);
    return {
      ready: Number.isInteger(n) && n >= 0,
      why: Number.isInteger(n) && n >= 0 ? null : \`scrollback is \${JSON.stringify(raw)}\`,
      scrollback: n,
      cols: term.cols,
      rows: term.rows,
    };
  })()`);

/**
 * The capacity record a scenario carries: the exact argument the app was
 * launched with, the number it came from and where that number was read.
 * The report publishes this per scenario, because the flag is the only
 * thing that turns native reflow on and its value decides how much
 * scrollback the region may count on.
 */
const capacityRecord = (read, at) => ({
  flag: `${CAPACITY_FLAG}${read.scrollback}`,
  rows: read.scrollback,
  readFrom: 'window.term.options.scrollback (this tab, at launch)',
  readAt: { cols: at?.cols ?? null, rows: at?.rows ?? null },
  meaning:
    'the scrollback this pty really has, passed to the app as its declared native retention capacity; the examples build Region.TerminalReflow .{.non_cursor_rows=.{.scrollback_rows=N}} from it and stay .none without it',
});

/**
 * The whole real terminal state for an ownership checkpoint, read from
 * ttyd's `window.term` in the PAGE MAIN WORLD. EVERY buffer row is
 * recorded — empty ones included, because an empty row that still carries
 * the wrap flag is itself reflow evidence — with the wrap flag and the
 * text the line really holds.
 *
 * `text` comes from the line's own translateToString: a cell the terminal
 * never wrote is a SPACE, and building the string from getChars() alone
 * would delete exactly those spaces — the candidate indentation, the gap
 * inside a status row, the space of the input row — and turn the real
 * 'skript> d' into 'skript>d'. The per-cell walk below is kept as the raw
 * cell evidence it is: how many cells the row really uses, and its inverse
 * runs, because the REPL draws the selected candidate and the cursor block
 * as styled cells and the selection is read out of cells, not guessed from
 * the text. The marker counts are taken over EVERY row of the buffer, not
 * over the bounded record, so the record's bound can never hide a lost or
 * doubled marker.
 */
const ownershipReadSource = (probe) => `(() => {
  const term = window.term;
  if (!term || !term.buffer || !term.buffer.active) return { ready: false };
  const buf = term.buffer.active;
  const markers = ${JSON.stringify(probe.markers)};
  const maxBufferRows = ${probe.maxBufferRows};
  const cell = buf.getNullCell();
  const cols = term.cols;
  const rows = term.rows;
  const row = (y) => {
    const line = buf.getLine(y);
    if (!line) return null;
    const chars = [];
    const inverse = [];
    let used = 0;
    let start = -1;
    for (let x = 0; x < cols; x++) {
      const c = line.getCell(x, cell);
      const glyph = c ? c.getChars() : '';
      chars.push(glyph);
      if (glyph !== '') used = x + 1;
      const inv = !!(c && c.isInverse());
      if (inv && start < 0) start = x;
      if (!inv && start >= 0) { inverse.push([start, x - start]); start = -1; }
    }
    if (start >= 0) inverse.push([start, cols - start]);
    let inverseCells = 0;
    const inverseText = [];
    for (const span of inverse) {
      inverseCells += span[1];
      const covered = chars.slice(span[0], span[0] + span[1]).join('').trim();
      if (covered !== '') inverseText.push(covered);
    }
    return {
      y,
      wrapped: line.isWrapped,
      cells: used,
      text: line.translateToString(true),
      inverse,
      inverseCells,
      inverseText,
    };
  };
  const counts = new Map(markers.map((m) => [m, 0]));
  const every = [];
  for (let y = 0; y < buf.length; y++) {
    const r = row(y);
    if (!r) continue;
    every.push(r);
    const key = r.text.trim();
    if (counts.has(key)) counts.set(key, counts.get(key) + 1);
  }
  const total = every.length;
  const kept = total > maxBufferRows ? every.slice(total - maxBufferRows) : every;
  const screen = [];
  for (let y = buf.viewportY; y < buf.viewportY + rows; y++) screen.push(row(y));
  const box = (sel) => {
    const el = document.querySelector(sel);
    if (!el) return null;
    const b = el.getBoundingClientRect();
    return { x: b.x, y: b.y, width: b.width, height: b.height };
  };
  const grid = box('.xterm-screen');
  const container = box('#terminal-container');
  const terminal = document.querySelector('.xterm');
  const bottomPadding = terminal ? Number.parseFloat(getComputedStyle(terminal).paddingBottom) : 0;
  return {
    ready: true,
    cols,
    rows,
    viewport: { width: window.innerWidth, height: window.innerHeight },
    viewportY: buf.viewportY,
    baseY: buf.baseY,
    length: buf.length,
    cursor: {
      x: buf.cursorX,
      y: buf.baseY + buf.cursorY - buf.viewportY,
      absY: buf.baseY + buf.cursorY,
    },
    screen,
    buffer: { rows: kept, total, keptCount: kept.length, dropped: total - kept.length },
    markerCounts: Object.fromEntries(counts),
    geometry: {
      cellHeight: grid && rows ? grid.height / rows : 0,
      chrome:
        grid && container
          ? grid.y + Math.max(0, window.innerHeight - (container.y + container.height)) + bottomPadding
          : 0,
      grid,
      container,
    },
  };
})()`;

const readOwnership = (tab, probe) => tab.evaluate(ownershipReadSource(probe));

const addCheck = (checkpoint, name, ok, detail) => {
  checkpoint.checks.push({ name, ok, detail });
  if (!ok) checkpoint.ok = false;
  return checkpoint;
};

/**
 * East Asian wide ranges, as much of Unicode's East Asian Width as this
 * driver can type: a lead in one of them needs TWO terminal columns, so
 * it never fits into the single column an odd-width row has left. That
 * one column is native PADDING, not original content (the installed
 * xterm leaves it blank), and it is what tells a re-emitted split row
 * apart from a row that simply ends.
 */
const WIDE_RANGES = Object.freeze([
  [0x1100, 0x115f], // Hangul Jamo
  [0x2e80, 0x303e], // CJK radicals, Kangxi, punctuation
  [0x3041, 0x33ff], // Hiragana .. CJK compatibility
  [0x3400, 0x4dbf], // CJK extension A
  [0x4e00, 0x9fff], // CJK unified ideographs
  [0xa000, 0xa4cf], // Yi
  [0xac00, 0xd7a3], // Hangul syllables
  [0xf900, 0xfaff], // CJK compatibility ideographs
  [0xfe30, 0xfe4f], // CJK compatibility forms
  [0xff00, 0xff60], // Fullwidth forms
  [0xffe0, 0xffe6],
  [0x1f300, 0x1f64f], // Emoji
  [0x20000, 0x3fffd], // CJK extension B
]);

/** Columns one glyph needs: two for a lead in a wide range. */
const glyphWidth = (ch) => {
  const cp = ch.codePointAt(0);
  if (cp === undefined) return 1;
  for (const [lo, hi] of WIDE_RANGES) if (cp >= lo && cp <= hi) return 2;
  return 1;
};

/** Columns the first glyph of a row really needs. */
const firstGlyphWidth = (text) => (text === '' ? 1 : glyphWidth(text));

/** Every glyph's column count, in order. */
const glyphWidths = (text) => [...text].map((ch) => glyphWidth(ch));

/**
 * How many terminal rows this line packs into at `cols` columns: greedy
 * first fit, which is what a terminal reflow does — a width-two glyph that
 * does not fit the columns a row has left moves WHOLE to the next row and
 * the leftover column is the terminal's padding, not content. So
 * ceil(columns/cols) is right only when no split boundary lands mid-glyph,
 * and this is the count the input contract compares against instead.
 */
const packedRows = (widths, cols) => {
  let rows = 1;
  let used = 0;
  for (const w of widths) {
    if (used + w > cols) {
      rows += 1;
      used = 0;
    }
    used += w;
  }
  return rows;
};

/**
 * The prefix of `line` that fits `cols` columns, cut exactly the way
 * Buffer.draw cuts it: grapheme by grapheme, a width-two glyph that would
 * cross the right edge moving WHOLE along with the rest the app never
 * paints. The REPL's band is ONE row — drawBand paints prompt + active line
 * at row 0 and never wraps — so at a narrow width this is what the input
 * row really holds, and NOT a re-join of several rows the app wrote.
 */
const clippedPrefix = (line, cols) => {
  let out = '';
  let used = 0;
  for (const ch of line) {
    const w = glyphWidth(ch);
    if (used + w > cols) break;
    out += ch;
    used += w;
  }
  return out;
};

/**
 * One LOGICAL band row: the row the app asked for plus every physical row
 * the terminal holds for it. A row wider than the terminal is ONE hard row
 * for the app and SEVERAL physical rows for the terminal, so every contract
 * compares logical text and the report keeps the physical rows, the join
 * that produced them and the columns each chunk really used.
 */
const newLogicalRow = (row, kind) => ({
  kind,
  firstRow: row.y,
  lastRow: row.y,
  text: row.text,
  // Columns the LAST physical row really used — what decides whether the
  // next row continues this one. A wide glyph's continuation cell holds no
  // text and does not count, so this is the logical column count.
  tailCells: row.cells,
  rows: [row],
  joins: [],
});

/** One more physical row for a logical row; `why` records the evidence. */
const pushChunk = (logical, row, why) => {
  logical.rows.push(row);
  logical.lastRow = row.y;
  logical.text += row.text;
  logical.tailCells = row.cells;
  logical.joins.push({ y: row.y, why });
};

/**
 * One band group, built from the rows themselves: the band's own first row
 * (REPL input row, statusline badge row) plus the rows directly under it.
 * `rows` are LOGICAL rows; `physicalRows` and `visibleRows` are the real
 * terminal rows behind them.
 */
const newGroup = (row, repl) => ({
  firstRow: row.y,
  lastRow: row.y,
  inputRow: repl ? row.y : null,
  inputText: repl ? row.text : null,
  inputRows: 1,
  barRow: repl ? null : row.y,
  statusRow: null,
  statusText: null,
  candidateRows: [],
  candidates: [],
  selected: [],
  rows: [],
  physicalRows: [],
  // The subset of `physicalRows` the terminal is actually showing.
  // Off-viewport rows are archived too — they are just not VISIBLE, and
  // visibility is the only thing the residue contract judges.
  visibleRows: [],
});

/** Add one of the band's own logical rows (input, candidate, band, status). */
const pushGroupRow = (group, row, kind) => {
  const logical = newLogicalRow(row, kind);
  group.rows.push(logical);
  group.physicalRows.push(row);
  group.lastRow = row.y;
  if (row.visible) group.visibleRows.push(row);
  if (RE_INPUT.test(logical.text)) return; // the cursor block is not a selection
  if (row.inverseText.length) group.selected.push(...row.inverseText);
  if (kind === 'status') {
    group.statusRow = logical.firstRow;
    group.statusText = logical.text;
  }
  if (kind === 'candidate') {
    group.candidateRows.push(logical.firstRow);
    group.candidates.push(logical.text.trim());
  }
};

/**
 * Add the physical row that carries the REST of the group's current
 * logical row, and keep the group's input text in step with it.
 */
const pushContinuation = (group, row, why) => {
  const logical = group.rows.at(-1);
  pushChunk(logical, row, why);
  group.physicalRows.push(row);
  group.lastRow = row.y;
  if (row.visible) group.visibleRows.push(row);
  const input = group.rows[0];
  if (input?.kind === 'input') {
    group.inputText = input.text;
    group.inputRows = input.rows.length;
  }
};

/**
 * Does this row carry the REST of the logical row above it?
 *
 * `wrap-flag`: the TERMINAL made the row by wrapping — installed xterm
 * sets `isWrapped` on every line its own reflow creates
 * (`_reflowSmaller` splits a hard line longer than the new columns) and a
 * wide glyph's continuation cell carries no text, so the re-joined text
 * is exactly the missing text.
 *
 * `full-row` / `no-fit`: the APP re-emitted the split itself, with CRLF,
 * which sets `isWrapped = false` (`lineFeed` clears the flag on the line
 * it moves into). Then the previous row is full, or it stopped short only
 * because a width-two glyph would not fit — the leftover column is the
 * terminal's own padding, never original content, so the row really does
 * continue the one above.
 *
 * A continuation is the row DIRECTLY below its source — nothing between —
 * and a candidate-shaped row joins on the wrap flag ONLY: an indented popup
 * row that happens to follow a full row is residue, never a continuation.
 */
const continuationOf = (group, row, cols, candidateShaped) => {
  if (!group) return null;
  const last = group.rows.at(-1);
  if (!last || row.y !== last.lastRow + 1) return null;
  if (row.wrapped === true) return 'wrap-flag';
  if (candidateShaped) return null;
  const used = last.tailCells;
  if (used <= 0) return null;
  if (used + firstGlyphWidth(row.text) > cols)
    return used >= cols ? 'full-row' : 'no-fit';
  return null;
};

/**
 * Walk the recorded buffer once and label every row. The BOTTOM-MOST group
 * the terminal is SHOWING is the live band, and the rule is structural, not
 * positional: a region anchors at the terminal's bottom.
 *
 * A group ABOVE the live one is an archived band — rows the region owned
 * before a geometry change and does not own now. `archivedGroups` are the
 * ones the terminal is still showing and `archivedOffscreen` the ones it
 * has scrolled past. Scrolling one out of view hides it; it does not make
 * it history, and nothing here claims a shrunken band committed the rows
 * it gave up. Both lists are recorded in full, and the only thing judged
 * automatically is CURRENTLY VISIBLE residue, because that is what a user
 * sees. Nothing is dropped: every row keeps its text, wrap flag, cell count
 * and selection, and a row belonging to neither the band, nor the markers,
 * nor this driver's own echoed commands or exit line is listed as `unowned`
 * instead of being filtered away.
 *
 * A band row wider than the terminal is one hard row for the app and
 * several physical rows for the terminal. Those rows are the BAND's own,
 * so they join its current logical row (with the join recorded) instead of
 * being filed as residue — an input line split by a reflow is still the
 * input line, and calling its tail unowned content would invent a defect
 * out of the driver's own decoder.
 */
function classifyBuffer(ctx, scenario, state) {
  const repl = scenario !== 'statusline';
  const markers = ctx.probe.markers;
  const cols = state.cols;
  // This driver's OWN exit line — the same pattern the exit checks use, so
  // a row classified here is exactly the row they look for. It belongs to
  // the launcher: neither the app's, nor an unowned leftover.
  const exitRow = exitPattern(ctx);
  const source = state.buffer.rows;
  const rows = [];
  const groups = [];
  const statusRows = [];
  const unowned = [];
  const joins = [];
  let open = null;
  let i = 0;
  while (i < source.length) {
    const raw = source[i];
    const visible = raw.y >= state.viewportY && raw.y < state.viewportY + state.rows;
    const row = { ...raw, visible, kind: null };
    rows.push(row);
    i += 1;
    const trimmed = raw.text.trim();
    if (trimmed === '') {
      row.kind = 'empty';
      continue;
    }
    if (markers.includes(trimmed)) {
      row.kind = 'marker';
      continue;
    }
    if (exitRow.test(trimmed)) {
      row.kind = 'exit';
      open = null;
      continue;
    }
    if (repl ? RE_INPUT.test(raw.text) : SL_BADGE.test(raw.text)) {
      row.kind = repl ? 'input' : 'bar';
      open = newGroup(row, repl);
      pushGroupRow(open, row, row.kind);
      groups.push(open);
      continue;
    }
    if (repl && RE_STATUS.test(raw.text)) {
      row.kind = 'status';
      statusRows.push(raw.y);
      if (open) pushGroupRow(open, row, 'status');
      // The status row is the band's LAST row and the one the cursor parks
      // on, so nothing continues it: a wrapped row below it is residue.
      open = null;
      continue;
    }
    const candidateShaped = repl ? RE_CANDIDATE.test(raw.text) : true;
    const why = continuationOf(open, raw, cols, candidateShaped);
    if (why) {
      row.kind = 'continuation';
      pushContinuation(open, row, why);
      joins.push({
        y: row.y,
        of: open.rows.at(-1).kind,
        after: open.rows.at(-1).firstRow,
        why,
        wrapped: raw.wrapped,
        cells: raw.cells,
        text: raw.text.slice(0, 48),
      });
      continue;
    }
    // A candidate INSIDE an open band group is the band's, full stop. The
    // shell-echo test comes after it on purpose: it matches single words,
    // and 'def' or 'deg->rad' would otherwise be filed as echo and the
    // popup rows this recipe is here to read would vanish from the record.
    if (open && candidateShaped) {
      row.kind = repl ? 'candidate' : 'band';
      pushGroupRow(open, row, row.kind);
      continue;
    }
    if (isTypedEcho(raw.text, ctx.commands)) {
      row.kind = 'shell';
      open = null;
      continue;
    }
    row.kind = 'unowned';
    unowned.push(row);
    open = null;
  }
  const onScreen = groups.filter((group) => group.visibleRows.length > 0);
  return {
    rows,
    groups,
    statusRows,
    joins,
    unowned,
    unownedVisible: unowned.filter((row) => row.visible),
    onScreenGroups: onScreen.map((group) => group.firstRow),
    liveGroupIndex: onScreen.length ? groups.indexOf(onScreen.at(-1)) : -1,
  };
}

const findCheckpoint = (checkpoints, scenario, name) =>
  checkpoints.find((c) => c.scenario === scenario && c.name === name) ?? null;

/**
 * One row of the live band against the same row of an earlier checkpoint: a
 * strict prefix proves the narrower geometry really re-wrapped the row, and
 * equality proves the round trip brought the whole row back. A missing
 * reference or a missing row fails the check — it never passes silently.
 *
 * `spec.physical` compares the real TERMINAL rows instead of the logical
 * band rows: a band row the terminal split across several rows is one row
 * for the app, and only its physical rows show where the split fell.
 */
function compareRow(checkpoint, all, spec, mode) {
  const which = spec.physical ? 'physicalRows' : 'rows';
  const name = spec.physical
    ? `physical-row-${mode === 'prefix' ? 'strict-prefix-of' : 'equals-reference'}`
    : mode === 'prefix'
      ? 'row-strict-prefix-of'
      : 'row-equals-reference';
  const got = checkpoint.liveGroup?.[which]?.[spec.row]?.text ?? null;
  const ref = findCheckpoint(all, checkpoint.scenario, spec.checkpoint);
  const want = ref?.liveGroup?.[which]?.[spec.row]?.text ?? null;
  if (got === null || want === null)
    return addCheck(
      checkpoint,
      name,
      false,
      got === null
        ? `live row ${spec.row} is not in the buffer`
        : `${spec.checkpoint} has no live row ${spec.row} to compare with`,
    );
  const ok = mode === 'prefix' ? got.length < want.length && want.startsWith(got) : got === want;
  return addCheck(
    checkpoint,
    name,
    ok,
    `${JSON.stringify(got)} ${mode === 'prefix' ? 'vs prefix of' : 'vs'} ${spec.checkpoint}: ${JSON.stringify(want)}`,
  );
}

/**
 * The geometry the recipe actually asked for. A refit that never landed
 * would make every other check here pass trivially, so the measured cols
 * and rows are compared against the request — against the recipe's own
 * numbers where it pinned one, and against an earlier checkpoint where the
 * roundtrip is the point.
 */
function geometryChecks(checkpoint, all, expect) {
  if (expect.rows !== undefined)
    addCheck(
      checkpoint,
      'measured-rows',
      checkpoint.rows === expect.rows,
      `terminal really measures ${checkpoint.rows} row(s), the recipe asked for ${expect.rows}`,
    );
  if (expect.rowsGreaterThan !== undefined)
    addCheck(
      checkpoint,
      'measured-rows',
      checkpoint.rows > expect.rowsGreaterThan,
      `terminal really measures ${checkpoint.rows} row(s), the recipe asked for more than ${expect.rowsGreaterThan}`,
    );
  if (expect.colsEqualTo || expect.colsLessThan) {
    const refName = expect.colsEqualTo ?? expect.colsLessThan;
    const ref = findCheckpoint(all, checkpoint.scenario, refName);
    const ok = expect.colsEqualTo
      ? !!ref && checkpoint.cols === ref.cols
      : !!ref && checkpoint.cols < ref.cols;
    addCheck(
      checkpoint,
      expect.colsEqualTo ? 'cols-round-trip' : 'cols-reflowed',
      ok,
      `${checkpoint.cols} col(s) now, ${refName} measured ${ref?.cols ?? 'nothing'}`,
    );
  }
  // Native reflow has to survive an ODD column count: a width-two glyph
  // leaves a half row at the end of every chunk, and that leftover column
  // is the terminal's padding rather than anything the app ever wrote.
  if (expect.oddCols !== undefined)
    addCheck(
      checkpoint,
      'cols-odd',
      expect.oddCols ? checkpoint.cols % 2 === 1 : checkpoint.cols % 2 === 0,
      `terminal really measures ${checkpoint.cols} col(s), ${expect.oddCols ? 'which is odd' : 'which is even'} as the recipe asked`,
    );
  return checkpoint;
}

function replChecks(checkpoint, all) {
  const expect = checkpoint.expect;
  geometryChecks(checkpoint, all, expect);
  const bandShaped = [
    'input',
    'candidates',
    'selected',
    'status',
    'rowPrefixOf',
    'rowEquals',
    'inputPacked',
    'inputRows',
    'nativeWrapOf',
    'statusOnce',
    'cursorBottom',
    'clipped',
  ].some((field) => expect[field] !== undefined);
  if (!bandShaped) return checkpoint;
  addCheck(
    checkpoint,
    'one-live-group',
    checkpoint.onScreenGroups.length === 1,
    `${checkpoint.onScreenGroups.length} band group(s) on screen (${checkpoint.groups.length} in the whole buffer, ${checkpoint.archivedOffscreen.length} of them archived above the viewport)`,
  );
  const live = checkpoint.liveGroup;
  if (!live)
    return addCheck(
      checkpoint,
      'pending-input',
      false,
      'no band group on screen: the band is not in the viewport at all',
    );
  if (expect.input !== undefined) {
    const want = `${OWN.prompt} ${expect.input}`.trimEnd();
    addCheck(
      checkpoint,
      'pending-input',
      live.inputText.trimEnd() === want,
      `live input row ${JSON.stringify(live.inputText.trimEnd())}, expected ${JSON.stringify(want)}`,
    );
  }
  if (expect.candidates !== undefined)
    addCheck(
      checkpoint,
      'popup-rows',
      live.candidates.length === expect.candidates,
      `${live.candidates.length} candidate row(s) ${JSON.stringify(live.candidates)}, expected ${expect.candidates}`,
    );
  if (expect.selected !== undefined) {
    const got = live.selected.join(' ');
    addCheck(
      checkpoint,
      'popup-selection',
      got === (expect.selected ?? ''),
      `inverse-highlighted candidate ${JSON.stringify(got)}, expected ${JSON.stringify(expect.selected ?? '')}`,
    );
  }
  if (expect.status !== undefined) {
    const inBand = live.statusRow === null ? 0 : 1;
    addCheck(
      checkpoint,
      'status-row',
      inBand === expect.status,
      `${inBand} status row(s) in the live band, expected ${expect.status}`,
    );
  }
  if (expect.inputPacked !== undefined) {
    // How many terminal rows the typed line packs into at the MEASURED
    // columns: greedy first fit over the real glyph widths, so a split
    // boundary that lands mid-glyph is counted the way a terminal splits
    // it (the glyph moves whole, the leftover column is padding). This is
    // about the rows the APP's own band row occupies; the terminal's own
    // reflow of a RETIRED hard row is `nativeWrapOf` below, and the two
    // are never the same claim.
    const widths = glyphWidths(`${OWN.prompt} ${expect.input}`);
    const want = packedRows(widths, checkpoint.cols);
    addCheck(
      checkpoint,
      'input-packed-rows',
      live.inputRows === want,
      `${live.inputRows} physical row(s) carry the ${widths.reduce((a, b) => a + b, 0)}-column input at ${checkpoint.cols} col(s); first-fit packing of its ${widths.length} glyph(s) is ${want}`,
    );
  }
  if (expect.inputRows !== undefined)
    addCheck(
      checkpoint,
      'input-physical-rows',
      live.inputRows === expect.inputRows,
      `the live band's input row occupies ${live.inputRows} physical terminal row(s) ${JSON.stringify((live.rows[0]?.joins ?? []).map((j) => j.why))}, the recipe states ${expect.inputRows}`,
    );
  if (expect.nativeWrapOf !== undefined) {
    // Terminal-NATIVE reflow, proved on the source the app retired.
    //
    // The REPL paints its pending line as ONE clipped row, so at a narrow
    // width the app can only show a prefix. The whole line still has to
    // exist SOMEWHERE, and where it exists is the terminal's own reflow of
    // the hard row the band used to own — an ARCHIVED group whose re-joined
    // text is the full line and whose physical rows are exactly the greedy
    // first-fit packing at the measured columns. A prefix-only band with no
    // such archived source means the reflowed source was destroyed; a
    // source whose row count differs means the split did not happen where a
    // real terminal splits a width-two glyph.
    const line = `${OWN.prompt} ${expect.nativeWrapOf}`;
    const widths = glyphWidths(line);
    const wantRows = packedRows(widths, checkpoint.cols);
    const archived = [...checkpoint.archivedGroups, ...checkpoint.archivedOffscreen];
    const inputOf = (group) => (group.rows[0]?.kind === 'input' ? group.rows[0] : null);
    const hit =
      archived.find(
        (group) =>
          inputOf(group)?.rows.length === wantRows &&
          inputOf(group)?.text.trimEnd() === line.trimEnd(),
      ) ?? null;
    addCheck(
      checkpoint,
      'retired-source-native-wrapped',
      hit !== null,
      `no ARCHIVED band group carries the ${widths.reduce((a, b) => a + b, 0)}-column source in the ${wantRows} physical row(s) greedy first fit needs at ${checkpoint.cols} col(s); archived group(s) were ${JSON.stringify(
        archived.map((group) => {
          const input = inputOf(group);
          return {
            firstRow: group.firstRow,
            visible: group.visibleRows.length > 0,
            inputRows: input ? input.rows.length : null,
            input: input ? input.text.trimEnd().slice(0, 96) : null,
            joins: input ? input.joins.map((j) => j.why) : [],
          };
        }),
      ).slice(0, 900)}`,
    );
    if (hit)
      addCheck(
        checkpoint,
        'split-made-by-the-terminal',
        hit.rows[0].joins.length > 0 &&
          hit.rows[0].joins.every((j) => j.why === 'wrap-flag'),
        `every split of the retired ${wantRows}-row source carries the terminal's OWN wrap flag (app re-emission would clear it): ${JSON.stringify(hit.rows[0].joins)}`,
      );
  }
  if (expect.statusOnce !== undefined)
    addCheck(
      checkpoint,
      'one-status-row',
      checkpoint.statusRows.length === expect.statusOnce,
      `${checkpoint.statusRows.length} status row(s) in the WHOLE buffer ${JSON.stringify(checkpoint.statusRows)}, expected ${expect.statusOnce}`,
    );
  if (expect.cursorBottom !== undefined)
    addCheck(
      checkpoint,
      'cursor-on-band-bottom',
      live.physicalRows.every((r) => r.visible) && checkpoint.cursor.absY === live.lastRow,
      `${live.physicalRows.filter((r) => r.visible).length} of ${live.physicalRows.length} band row(s) on screen; the cursor sits at buffer row ${checkpoint.cursor.absY} and the live band's last row is ${live.lastRow}`,
    );
  if (expect.clipped !== undefined) {
    // The band's PHYSICAL extent against the viewport: rows of the band
    // above the viewport are the rows a height clip retired, never history.
    const off = live.physicalRows.filter((r) => !r.visible);
    addCheck(
      checkpoint,
      'band-physically-clipped',
      (off.length > 0) === expect.clipped,
      `${off.length} of ${live.physicalRows.length} band row(s) sit above the viewport ${JSON.stringify(off.map((r) => r.y))}, so the band ${off.length ? 'WAS' : 'was NOT'} physically clipped`,
    );
  }
  if (expect.rowPrefixOf) compareRow(checkpoint, all, expect.rowPrefixOf, 'prefix');
  if (expect.rowEquals) compareRow(checkpoint, all, expect.rowEquals, 'equals');
  return checkpoint;
}

function statuslineChecks(checkpoint, all) {
  const expect = checkpoint.expect;
  geometryChecks(checkpoint, all, expect);
  if (expect.bandRows === undefined) return checkpoint;
  addCheck(
    checkpoint,
    'one-live-group',
    checkpoint.onScreenGroups.length === 1,
    `${checkpoint.onScreenGroups.length} band group(s) on screen (${checkpoint.groups.length} in the whole buffer, ${checkpoint.archivedOffscreen.length} of them archived above the viewport)`,
  );
  const live = checkpoint.liveGroup;
  if (!live)
    return addCheck(
      checkpoint,
      'band-rows',
      false,
      'no badge row on screen: the band is not in the viewport at all',
    );
  addCheck(
    checkpoint,
    'band-rows',
    live.rows.length === expect.bandRows,
    `${live.rows.length} band row(s) ${JSON.stringify(live.rows.map((r) => r.text.slice(0, 48)))}, expected ${expect.bandRows}`,
  );
  const [bar, gauge, message] = live.rows;
  if (bar) {
    const tail = RE_TAIL.exec(bar.text)?.[1] ?? null;
    addCheck(
      checkpoint,
      'band-badge',
      bar.text.includes(OWN.badge),
      `band row 0 is ${JSON.stringify(bar.text)}`,
    );
    if (expect.tail === true)
      addCheck(
        checkpoint,
        'width-tail',
        tail !== null && Number(tail) === checkpoint.cols,
        `statusbar reports ${JSON.stringify(tail)}, the terminal really measures ${checkpoint.cols} col(s)`,
      );
    else if (expect.tail === false)
      addCheck(
        checkpoint,
        'width-tail',
        tail === null,
        `statusbar still reports ${JSON.stringify(tail)} where the row is too narrow to hold it`,
      );
    else
      addCheck(
        checkpoint,
        'width-tail-not-stale',
        tail === null || Number(tail) === checkpoint.cols,
        `statusbar reports ${JSON.stringify(tail)}, the terminal really measures ${checkpoint.cols} col(s)`,
      );
  }
  if (gauge)
    addCheck(
      checkpoint,
      'gauge-row',
      gauge.text.includes(OWN.gauge) && gauge.text.includes('%'),
      `band row 1 is ${JSON.stringify(gauge.text)}`,
    );
  if (message)
    addCheck(
      checkpoint,
      'message-row',
      message.text.startsWith(OWN.message),
      `band row 2 is ${JSON.stringify(message.text.slice(0, 60))}`,
    );
  if (expect.rowPrefixOf) compareRow(checkpoint, all, expect.rowPrefixOf, 'prefix');
  if (expect.rowEquals) compareRow(checkpoint, all, expect.rowEquals, 'equals');
  return checkpoint;
}

/**
 * The contracts every checkpoint carries. The 36 committed markers must
 * each sit on exactly one row, the record must be complete enough to judge
 * ownership at all, and — once the app owns the band — nothing the band
 * painted may still be VISIBLE that the band does not own now: no band
 * group above the live one, and no row belonging to neither the band, nor
 * the markers, nor this driver's own echoed commands or exit line. The
 * scrollback is deliberately not judged: an archived band the terminal has
 * scrolled past is still an archived band, so it is recorded in full and
 * named in the detail rather than passed off as history.
 */
function judge(ctx, checkpoint, all) {
  const missing = [];
  const doubled = [];
  for (const marker of ctx.probe.markers) {
    const n = checkpoint.markerCounts[marker] ?? 0;
    if (n === 0) missing.push(marker);
    else if (n > 1) doubled.push({ marker, count: n });
  }
  addCheck(
    checkpoint,
    'committed-markers-once',
    missing.length === 0 && doubled.length === 0,
    `missing=${JSON.stringify(missing)} doubled=${JSON.stringify(doubled)}`,
  );
  addCheck(
    checkpoint,
    'buffer-record-complete',
    checkpoint.buffer.dropped === 0,
    `${checkpoint.buffer.total} buffer row(s), ${checkpoint.buffer.keptCount} recorded, ${checkpoint.buffer.dropped} dropped — a truncated record cannot judge band ownership`,
  );
  if (checkpoint.owned)
    addCheck(
      checkpoint,
      'no-visible-stale-owned-rows',
      checkpoint.archivedGroups.length === 0 && checkpoint.unownedVisible.length === 0,
      `CURRENTLY VISIBLE residue only: ${checkpoint.archivedGroups.length} archived band group(s) and ${checkpoint.unownedVisible.length} unowned row(s) on screen — ${JSON.stringify([
        ...checkpoint.archivedGroups.map((group) => ({
          visibleRows: group.visibleRows.map((r) => r.y),
          input: group.inputText,
          selected: group.selected,
        })),
        ...checkpoint.unownedVisible.map((r) => ({ y: r.y, wrapped: r.wrapped, text: r.text.slice(0, 48) })),
      ]).slice(0, 900)}. This check does NOT judge the scrollback: ${checkpoint.archivedOffscreen.length} archived band group(s) and ${checkpoint.unowned.length - checkpoint.unownedVisible.length} unowned row(s) sit above the viewport and are recorded in archivedOffscreen / unowned — a physical shrink does not commit the rows the band gave up, so read them there`,
    );
  return checkpoint.scenario === 'statusline'
    ? statuslineChecks(checkpoint, all)
    : replChecks(checkpoint, all);
}

function buildCheckpoint(ctx, scenario, name, state, file, expect, owned, at, all) {
  const { rows, groups, statusRows, joins, unowned, unownedVisible, onScreenGroups, liveGroupIndex } =
    classifyBuffer(ctx, scenario, state);
  const above = groups.slice(0, Math.max(0, liveGroupIndex));
  const checkpoint = {
    scenario,
    name,
    file,
    phase: ctx.phase,
    cols: state.cols,
    rows: state.rows,
    viewport: state.viewport,
    viewportY: state.viewportY,
    baseY: state.baseY,
    bufferLength: state.length,
    geometry: state.geometry,
    cursor: state.cursor,
    expect,
    owned,
    screen: state.screen.filter(Boolean),
    buffer: { ...state.buffer, rows },
    markerCounts: state.markerCounts,
    groups,
    onScreenGroups,
    liveGroup: groups[liveGroupIndex] ?? null,
    archivedGroups: above.filter((group) => group.visibleRows.length > 0),
    archivedOffscreen: above.filter((group) => !group.visibleRows.length),
    statusRows,
    unowned,
    unownedVisible,
    joins,
    joinRule:
      'a band row wider than the terminal is ONE hard row for the app and SEVERAL physical rows for the terminal; those rows join the band\'s current logical row (wrap-flag = the terminal wrapped them, full-row / no-fit = the app re-emitted the split and the previous row ended only where a width-two glyph could not fit) so a reflowed input line is never reported as unowned residue. Each join records the row, the reason and its wrap flag under `joins`.',
    liveGroupRowMeaning:
      'liveGroup.rows are LOGICAL rows (text re-joined across the terminal rows that carry one band row); liveGroup.physicalRows / visibleRows are those real terminal rows, with per-row wrap flag and used cells.',
    liveGroupRule:
      'the bottom-most band group the terminal is SHOWING is the live band (a region anchors at the terminal bottom); every group above it is an archived band the band no longer owns, listed as archivedGroups while visible and archivedOffscreen once the terminal has scrolled past it — neither list is called history',
    checks: [],
    ok: true,
    at,
    atIso: new Date(at).toISOString(),
    sinceStartMs: at - ctx.startedAt,
    timeMeaning:
      "this driver process's own clock when the state above was read; it is not a claim about when the app painted the frame",
  };
  return judge(ctx, checkpoint, all);
}

/**
 * One ownership checkpoint: bounded settle, the real state, then the real
 * PNG — written before the contracts run, so a checkpoint that fails its
 * own contract still leaves the frame that shows why on disk.
 */
async function ownShot(ctx, scenario, name, expect, owned = true) {
  await sleep(SETTLE_MS);
  const state = await readOwnership(ctx.tab, ctx.probe);
  const at = Date.now(); // the driver's own clock, at the read — not a paint time
  if (!state.ready)
    throw new Error(`[ownership] ${scenario}/${name}: no window.term in the page main world`);
  const file = resolve(ctx.outputDir, `${ctx.pngPrefix}-${scenario}-${name}.png`);
  await screenshot(ctx.tab, file);
  return buildCheckpoint(ctx, scenario, name, state, file, expect, owned, at, [
    ...ctx.checkpoints,
  ]);
}

/**
 * The exit frame. The launcher's anchored `rc=` marker is the only proof
 * the app really exited, so both the marker and the exit code are contract
 * checks on the recorded frame — the run reports them and keeps going
 * rather than throwing here, so the JSON holds every failure there is.
 * The pattern is the same one the classifier gives the launcher's row, so
 * a row it calls an exit row is exactly the row the checks look for.
 */
async function ownExit(ctx, scenario, expect) {
  const pattern = exitPattern(ctx);
  await waitScreen(
    ctx.tab,
    `${scenario} exit marker`,
    (s) => s.screen.some((line) => pattern.test(line)),
    EXIT_MS,
  );
  const checkpoint = await ownShot(ctx, scenario, 'exit', expect);
  const line = checkpoint.screen.find((r) => pattern.test(r.text)) ?? null;
  const rc = line ? (/rc=(\d+)$/.exec(line.text)?.[1] ?? null) : null;
  checkpoint.exit = { marker: ctx.marker, line: line?.text ?? null, rc };
  addCheck(
    checkpoint,
    'exit-marker',
    line !== null,
    line
      ? `launcher printed ${JSON.stringify(line.text)}`
      : `no "VISUAL_EXIT ${ctx.marker} rc=<number>" row within ${EXIT_MS}ms`,
  );
  addCheck(checkpoint, 'exit-code', rc === '0', `app exited with rc=${rc ?? 'nothing'}`);
  return checkpoint;
}

/**
 * One scenario: one ttyd tab, one fresh pty, one fresh bash. The binary is
 * hashed BEFORE it is launched (an unreadable build is a launch failure,
 * not a capture), this terminal's own scrollback is read as the DECLARED
 * native capacity the app is launched with, the 36 committed marker rows are
 * printed before the app exists, and the tab is released in `finally`
 * whatever the scenario did.
 */
async function runOwnershipScenario(ctx, name, body, checkpoints) {
  const bin = resolve(ctx.repoRoot, 'zig-out/bin', BIN[name]);
  const binary = await binaryIdentity(bin);
  const tab = await openScenarioTab(ctx, name);
  const scenarioCtx = {
    ...ctx,
    tab,
    checkpoints,
    scenario: name,
    recipe: 'ownership',
    marker: `OWN-${ctx.phase.toUpperCase()}-${name.toUpperCase()}`,
    binary,
    capacity: null,
    // Only THIS pty's own typed commands: the marker loop and the launch
    // line, so an echoed row is never read against another scenario's text.
    commands: [ctx.markerCommand],
  };
  try {
    await resize(tab, WIDE);
    const booted = await waitScreen(
      tab,
      'ttyd terminal boot',
      (s) => s.cols > 0 && s.rows > 0,
      FIRST_FRAME_MS,
      true,
    );
    // The declared native capacity is read from THIS terminal before
    // anything is typed: it is the scrollback this pty really has, and it
    // is what the app is launched with. A terminal that cannot report it
    // cannot be launched with a truthful one.
    await declareCapacity(scenarioCtx, booted, 'ownership');
    await focusTerminal(tab);
    await type(tab, scenarioCtx.markerCommand);
    await press(tab, 'Enter');
    await waitScreen(
      tab,
      `${name} committed markers`,
      (s) => s.screen.some((line) => line.includes(ctx.probe.markers.at(-1))),
      FIRST_FRAME_MS,
      true,
    );
    checkpoints.push(
      await ownShot(
        scenarioCtx,
        name,
        'preapp-markers',
        {
          prose: `${ctx.probe.markers.length} distinct committed rows printed by this pty's bash on a cleared screen, before the app existed: the reference every later checkpoint measures committed history against`,
        },
        false,
      ),
    );
    await body(scenarioCtx, checkpoints);
  } finally {
    try {
      await tab.close();
    } catch {}
  }
  return {
    name,
    marker: scenarioCtx.marker,
    binary,
    capacity: scenarioCtx.capacity,
    commands: [...scenarioCtx.commands],
  };
}

/**
 * The launch command for one ownership scenario: the shared region-app
 * launch (binary plus its declared native scrollback capacity), remembered
 * so its echoed rows are not read as unowned content.
 */
const launchFor = (ctx, binAbs) => {
  if (!ctx.capacity)
    throw new Error('[ownership] the scenario has no declared capacity to launch with');
  return launchApp(ctx, binAbs);
};

// ── ownership scenario 1: the REPL popup across a physical height cycle ──
// The third candidate is selected on purpose: the highlighted row is what a
// stale group keeps highlighting, so archived residue is unmistakable in the
// recorded cells instead of being a row of plain text.
async function replOwnershipBody(ctx, checkpoints) {
  const bin = resolve(ctx.repoRoot, 'zig-out/bin', BIN.repl);
  const capture = (name, expect, owned) => ownShot(ctx, 'repl', name, expect, owned);
  await type(ctx.tab, launchFor(ctx, bin));
  await press(ctx.tab, 'Enter');
  const booted = await waitScreen(
    ctx.tab,
    'repl first frame',
    (s) => s.screen.some((line) => line.includes(OWN.status)),
    FIRST_FRAME_MS,
    true,
  );

  await type(ctx.tab, 'd');
  await press(ctx.tab, 'ArrowDown', 'ArrowDown');
  await waitScreen(
    ctx.tab,
    'repl popup open',
    (s) => s.screen.some((line) => RE_INPUT.test(line)),
    SOFT_MS,
  );
  checkpoints.push(
    await capture('wide-popup-selected-third', {
      prose: `the popup open at the full ${booted.cols}x${booted.rows} terminal with the THIRD candidate inverse-highlighted: one band group, the markers above it untouched, and the selection readable out of the cells`,
      input: 'd',
      candidates: 8,
      selected: 'deg->rad',
      status: 1,
      rows: booted.rows,
    }),
  );

  // Height-only refits at the real viewport sizes measured from this page.
  // The band shrinks, loses every row but its input, and grows back; the
  // regrowth to the full terminal height is where the pre-shrink group can
  // survive above the live one, with its own selection still highlighted.
  const six = rowsViewport(booted, SHORT_ROWS);
  const one = rowsViewport(booted, 1);
  await resizeAndAck(ctx.tab, six, 'repl height-6');
  checkpoints.push(
    await capture('height-6', {
      prose: `a ${SHORT_ROWS}-row terminal at ${six.width}x${six.height}px: the band is input + a windowed popup + status, still ONE group, and no row of the pre-shrink group is left above it`,
      input: 'd',
      candidates: 4,
      selected: 'deg->rad',
      status: 1,
      rows: SHORT_ROWS,
    }),
  );
  await resizeAndAck(ctx.tab, one, 'repl height-1');
  checkpoints.push(
    await capture('height-1', {
      prose: 'a 1-row terminal keeps the input row alone: no popup row, no status row, the typed "d" intact — the extreme the height cycle has to come back from',
      input: 'd',
      candidates: 0,
      selected: null,
      status: 0,
      rows: 1,
    }),
  );
  await resizeAndAck(ctx.tab, six, 'repl height-6-again');
  checkpoints.push(
    await capture('height-6-again', {
      prose: 'the same 6-row terminal again: the popup windows back around the same selection and the band is one group, not the 1-row group stacked on the 6-row one',
      input: 'd',
      candidates: 4,
      selected: 'deg->rad',
      status: 1,
      rows: SHORT_ROWS,
    }),
  );
  await resizeAndAck(ctx.tab, WIDE, 'repl wide-restored');
  checkpoints.push(
    await capture('wide-restored', {
      prose: `back at the full ${WIDE.width}px geometry after ${booted.rows} → ${SHORT_ROWS} → 1 → ${SHORT_ROWS} → wide (the recipe measured ${booted.cols}x${booted.rows} before the cycle): the live group carries the whole popup and the same third-candidate selection, and NOTHING of the shrunken band is left on screen above it`,
      input: 'd',
      candidates: 8,
      selected: 'deg->rad',
      status: 1,
      rowsGreaterThan: SHORT_ROWS,
    }),
  );

  // Escape while idle dismisses the popup, and the dismissal has to stand
  // through the app's own idle ticks and through a second Escape.
  await press(ctx.tab, 'Escape');
  checkpoints.push(
    await capture('escape-dismissed-idle', {
      prose: 'Esc on an idle app collapses the popup: the band is input + status, the typed "d" is untouched, the dismissed popup cannot re-open under the idle ticks the settle waited through, and no band row is left above the live group',
      input: 'd',
      candidates: 0,
      selected: null,
      status: 1,
    }),
  );
  await press(ctx.tab, 'Escape');
  checkpoints.push(
    await capture('escape-repeat-dismissed', {
      prose: 'a second Esc with no popup open is ignored by the app: the band stays two rows and does not grow, collapse or duplicate anything',
      input: 'd',
      candidates: 0,
      selected: null,
      status: 1,
      rowEquals: { checkpoint: 'escape-dismissed-idle', row: 1 },
    }),
  );

  // An edit re-arms completion, and Tab then accepts what the popup offers.
  await type(ctx.tab, 'e');
  await waitScreen(
    ctx.tab,
    'repl popup re-armed',
    (s) => s.screen.some((line) => /^skript> de\s*$/.test(line)),
    SOFT_MS,
  );
  checkpoints.push(
    await capture('edit-rearms-popup', {
      prose: 'one typed character re-arms the dismissed completion: the popup is back for the new token, windowed to the live group, with the selection back at the first candidate',
      input: 'de',
      candidates: 4,
      selected: 'def',
      status: 1,
    }),
  );
  await press(ctx.tab, 'Tab');
  await waitScreen(
    ctx.tab,
    'repl completion accepted',
    (s) => s.screen.some((line) => /^skript> def\s*$/.test(line)),
    SOFT_MS,
  );
  checkpoints.push(
    await capture('tab-accepted', {
      prose: 'Tab accepted the highlighted candidate: the input row reads the completed word, the popup is closed, and the band is back to input + status',
      input: 'def',
      candidates: 0,
      selected: null,
      status: 1,
    }),
  );

  // Width only, at the closed two-row band: the same owned rows reflow into
  // the narrow width and back, and the app must not report or keep a width
  // it no longer has.
  await resizeAndAck(ctx.tab, NARROW, 'repl width-narrow');
  checkpoints.push(
    await capture('width-narrow', {
      prose: `the two-row band at ${NARROW.width}px: the input row and the status row are the narrow prefix of their own wide text, reflowed by the terminal and repainted by the app — no wide row survives the reflow`,
      input: 'def',
      candidates: 0,
      status: 1,
      colsLessThan: 'tab-accepted',
      rowPrefixOf: { checkpoint: 'tab-accepted', row: 1 },
    }),
  );
  await resizeAndAck(ctx.tab, WIDE, 'repl width-restored-wide');
  checkpoints.push(
    await capture('width-restored-wide', {
      prose: 'back at the wide geometry: the status row is the very text it was before the reflow, the terminal really measures the same columns again, and the narrow band left no row behind',
      input: 'def',
      candidates: 0,
      status: 1,
      colsEqualTo: 'tab-accepted',
      rowEquals: { checkpoint: 'tab-accepted', row: 1 },
    }),
  );

  await ctrl(ctx.tab, 'd');
  checkpoints.push(
    await ownExit(ctx, 'repl', {
      prose: '^D quit: the launcher printed rc=0, the final band rows stay on screen, and no archived group is left visible among them',
      rowsGreaterThan: SHORT_ROWS,
    }),
  );
}

// ── ownership scenario 2: the statusline's own width roundtrip ───────────
// A fixed three-row band (StatusBar / Gauge / wrapped Text), the app's own
// width in its right tail, and a message that re-wraps at every width. The
// markers printed before the launch are the committed history it must not
// touch while it redraws underneath them.
async function statuslineOwnershipBody(ctx, checkpoints) {
  const bin = resolve(ctx.repoRoot, 'zig-out/bin', BIN.statusline);
  const capture = (name, expect, owned) => ownShot(ctx, 'statusline', name, expect, owned);
  await type(ctx.tab, launchFor(ctx, bin));
  await press(ctx.tab, 'Enter');
  const booted = await waitScreen(
    ctx.tab,
    'statusline first frame',
    (s) => s.screen.some((line) => /NORMAL|v\d+\.\d+\.\d+/.test(line)),
    FIRST_FRAME_MS,
    true,
  );
  checkpoints.push(
    await capture('wide', {
      prose: `the three-row band at ${booted.cols}x${booted.rows}: statusbar (with the width the app believes it has), gauge, wrapped message — one group, and the ${ctx.probe.markers.length} committed marker rows above it untouched`,
      bandRows: 3,
      tail: true,
    }),
  );
  await resizeAndAck(ctx.tab, NARROW, 'statusline narrow');
  checkpoints.push(
    await capture('narrow', {
      prose: `the same band at ${NARROW.width}px: still three rows, the message re-wrapped to the narrow width and the badge kept whole — no wide row survives the reflow and the app never reports a width it no longer has`,
      bandRows: 3,
      rowPrefixOf: { checkpoint: 'wide', row: 2 },
    }),
  );
  await resizeAndAck(ctx.tab, WIDE, 'statusline wide-restored');
  checkpoints.push(
    await capture('wide-restored', {
      prose: 'back at the wide geometry after the roundtrip: the message row is the text it was, the statusbar reports the columns the terminal really measures again, and the band is three rows with nothing left above it',
      bandRows: 3,
      tail: true,
      colsEqualTo: 'wide',
      rowEquals: { checkpoint: 'wide', row: 2 },
    }),
  );
  await press(ctx.tab, 'q');
  checkpoints.push(
    await ownExit(ctx, 'statusline', {
      prose: 'q quit: the launcher printed rc=0, the three final band rows stay on screen, and no row of either width is left stranded on them',
      rowsGreaterThan: SHORT_ROWS,
    }),
  );
}

// ── ownership scenario 3: one mixed ASCII + width-two glyph input line ───
// The typed line is 47 ASCII columns + 37 width-two glyphs + the REPL's own
// 8-column prompt: 129 columns, ONE hard row for the app and several
// physical rows for the terminal. The REPL does not wrap it — Buffer.draw
// clips, so the app's input row at a narrow width is the grapheme PREFIX
// that fits — and the cycle follows the real contract:
//
//   wide (2-row band) → clip to ONE row at that WIDE width → narrow to a
//   measured ODD column count while still one row → widen again while
//   still one row → restore the wide height → quit.
//
// Every step states what it really holds. At one row the app's own input row
// is the grapheme PREFIX that fits the measured columns — never a re-joined
// wrap, because Buffer.draw clips and drawBand paints the line on ONE row —
// and the one-row clip itself retired the band's OLD FIRST input row instead
// of leaving it half on screen, so no checkpoint here claims a clipped
// current band. The WHOLE line is proved elsewhere, and only there: as the
// TERMINAL's own reflow of the retired hard row, over an archived group,
// re-joined through the terminal's own wrap flag (`nativeWrapOf`) — the only
// proof the wide source survived the transition at all. The restore step
// states the exact original row, one status row in the WHOLE buffer and
// nothing of the geometries that came before it left visible.
async function mixOwnershipBody(ctx, checkpoints) {
  if (MIX.ascii.length !== 47)
    throw new Error(
      `[ownership] mix: the ASCII run is ${MIX.ascii.length} columns, this recipe states 47 and the reported column count follows from it`,
    );
  const bin = resolve(ctx.repoRoot, 'zig-out/bin', BIN.mix);
  const capture = (name, expect, owned) => ownShot(ctx, 'mix', name, expect, owned);
  await type(ctx.tab, launchFor(ctx, bin));
  await press(ctx.tab, 'Enter');
  const booted = await waitScreen(
    ctx.tab,
    'mix first frame',
    (s) => s.screen.some((row) => row.includes(OWN.status)),
    FIRST_FRAME_MS,
    true,
  );
  if (booted.cols < MIX.columns)
    throw new Error(
      `[ownership] mix: measured wide terminal is ${booted.cols} columns; the ${MIX.columns}-column source must fit in one hard row before native narrowing`,
    );
  // One burst of real keystrokes. Completion opens and closes again while
  // the token under the cursor changes, and the token that ends in a glyph
  // no candidate starts with leaves the popup closed for good.
  await type(ctx.tab, MIX.text);
  await waitScreen(
    ctx.tab,
    'mix input painted',
    (s) => s.screen.some((row) => row.includes(MIX.glyph) && row.includes(MIX.ascii.slice(0, 16))),
    SOFT_MS,
  );
  checkpoints.push(
    await capture('wide-mixed-input', {
      prose: `the ${MIX.columns}-column mixed line at the full ${booted.cols}x${booted.rows} terminal — ${MIX.ascii.length} ASCII columns and ${MIX.glyphs} width-two glyphs behind the ${`${OWN.prompt} `.length}-column prompt: ONE physical input row carrying the whole line (the REPL draws a single row and never wraps it), no popup row, one status row, and the cursor parked on the band's own last row`,
      input: MIX.text,
      inputPacked: true,
      inputRows: 1,
      candidates: 0,
      selected: null,
      status: 1,
      statusOnce: 1,
      clipped: false,
      cursorBottom: true,
      rows: booted.rows,
    }),
  );

  // The physical height clip comes FIRST, at this wide width: the band is
  // input + status, and a 1-row terminal keeps the INPUT row alone
  // (bandHeight(1, 0) == 1 in examples/skript_repl.zig), so the status row
  // has nowhere to go. Narrowing first would confound the two retirements.
  //
  // What that transition really does is RETIRE the band's OLD FIRST INPUT
  // ROW: a 1-row viewport cannot hold the two rows the band owned, that first
  // row scrolls out of it together with the status row, and the app repaints
  // the very same whole line on the one row the terminal still has. The live
  // band is therefore never half on screen — `clipped: true` would be a false
  // claim here, and a half-visible band row is not what this step produces.
  // What it does produce is a retired WIDE HARD ROW above the viewport, which
  // is why the narrowing below has to prove the whole line again out of the
  // TERMINAL's own reflow of that row (`nativeWrapOf`) instead of out of the
  // band, which now holds a prefix.
  //
  // At one row there is also no last row to park a cursor on and no status row
  // to draw, so this checkpoint claims neither: what is really available at
  // one row is the whole input line, a band that IS the single row the
  // terminal really has, and a status row that is not in it.
  const clip = rowsViewport(booted, MIX.clipRows, WIDE.width);
  await resizeAndAck(ctx.tab, clip, 'mix clip');
  checkpoints.push(
    await capture('clip-short', {
      prose: `the ${MIX.clipRows}-row terminal at ${clip.width}x${clip.height}px, still at the ${booted.cols} columns the whole ${MIX.columns}-column line needs: the physical transition RETIRED the band's old first input row and the app repainted the same whole line in ONE physical row on the one row the terminal now has, the status row has nowhere to go and is not painted at all, and the ${ctx.probe.markers.length} committed marker rows are scrolled above it untouched`,
      input: MIX.text,
      inputPacked: true,
      inputRows: 1,
      candidates: 0,
      selected: null,
      status: 0,
      colsEqualTo: 'wide-mixed-input',
      rows: MIX.clipRows,
    }),
  );

  // An ODD column count, measured rather than assumed: a width-two glyph
  // then straddles half of every split row, and the leftover column is the
  // terminal's own padding rather than anything the app wrote. The walk
  // keeps the ONE-row height the clip just took, so only the width moves.
  const odd = await fitOddCols(ctx.tab, 'mix narrow', { ...NARROW, height: clip.height });
  const narrowCols = odd.state.cols;
  // What the app can actually PAINT at those columns: Buffer.draw clips the
  // row and never wraps it, so the input row holds the grapheme prefix that
  // fits. The whole line is then nowhere in the band, and it survives only as
  // the TERMINAL's own reflow of the hard row the one-row clip retired —
  // which `nativeWrapOf` asserts below, over an ARCHIVED group, and not out
  // of the live one.
  const clipped = clippedPrefix(`${OWN.prompt} ${MIX.text}`, narrowCols).slice(
    `${OWN.prompt} `.length,
  );
  const narrowRows = packedRows(glyphWidths(`${OWN.prompt} ${MIX.text}`), narrowCols);
  checkpoints.push(
    await capture('narrow-odd', {
      prose: `the same ${MIX.columns}-column line at ${narrowCols} col(s) — an odd width reached by walking the viewport ${odd.attempts} step(s) of the measured ${Math.round(odd.cellWidth)}px cell — with the band still one row high: the app's own input row is CLIPPED to the ${clipped.length}-grapheme prefix that fits those columns (Buffer.draw drops the rest; it never wraps), and the whole line exists nowhere in the band: it survives only as the TERMINAL's own reflow of the hard row the one-row clip retired, now an archived group above the live band of ${narrowRows} physical rows packed first fit, every one of them re-joined through the terminal's OWN wrap flag (an app that re-emitted the split itself clears that flag) and every split boundary leaving the terminal's own padding behind`,
      input: clipped,
      inputRows: 1,
      nativeWrapOf: MIX.text,
      candidates: 0,
      selected: null,
      status: 0,
      rows: MIX.clipRows,
      colsLessThan: 'wide-mixed-input',
      oddCols: true,
      rowPrefixOf: { checkpoint: 'wide-mixed-input', row: 0, physical: true },
    }),
  );

  // Widen while the band is STILL one row high: one geometry change over a
  // retired prefix, which must not come back as live rows and must not be
  // applied twice. The input line fits one row again at this width, and that
  // is the app's own single clipped row, not the terminal's reflow.
  await resize(ctx.tab, { width: WIDE.width, height: clip.height });
  const widened = await settledState(ctx.tab, 'mix clip widened');
  checkpoints.push(
    await capture('clip-widened', {
      prose: `widened to ${widened.cols} col(s) while the band is still clipped to ${MIX.clipRows} row: the ${MIX.columns}-column line fits ONE physical input row again and the band is still that one row — the status row the clip took is still not painted — and nothing the narrow geometry retired is painted as if it were live`,
      input: MIX.text,
      inputPacked: true,
      inputRows: 1,
      candidates: 0,
      selected: null,
      status: 0,
      colsEqualTo: 'wide-mixed-input',
      rows: MIX.clipRows,
    }),
  );

  await resizeAndAck(ctx.tab, WIDE, 'mix height restored');
  checkpoints.push(
    await capture('height-restored', {
      prose: `the height restored to ${WIDE.height}px after the clip: the band's status row is back and it is the ONLY status row in the WHOLE buffer — the one the one-row clip retired is gone, not merely scrolled out of sight — the input row is the EXACT physical row it was before any narrowing, no row of the one-row, ${narrowCols}-column or clipped geometry is visible above it, and the ${ctx.probe.markers.length} committed marker rows are each still on exactly one row`,
      input: MIX.text,
      inputPacked: true,
      inputRows: 1,
      candidates: 0,
      selected: null,
      status: 1,
      statusOnce: 1,
      clipped: false,
      cursorBottom: true,
      colsEqualTo: 'wide-mixed-input',
      rowsGreaterThan: MIX.clipRows,
      rowEquals: { checkpoint: 'wide-mixed-input', row: 0, physical: true },
    }),
  );

  await ctrl(ctx.tab, 'd');
  checkpoints.push(
    await ownExit(ctx, 'mix', {
      prose: '^D quit: the launcher printed rc=0 with the mixed line and the status row still on screen, and the one-row, odd-width and restored geometries left no row of their own behind',
      rowsGreaterThan: MIX.clipRows,
    }),
  );
}

/**
 * Run the ownership recipes and return what to read. Three scenarios, one
 * fresh pty each, in `before`/`after` phases: the phase is the caller's own
 * label for the build under test and it names the PNGs and the report, so
 * the two runs never overwrite each other. A scenario that fails keeps its
 * PNGs, the next one still runs, and the report is written before any
 * failure is thrown.
 *
 * options: { baseUrl, outputDir, phase, binaryPrefix?, app?, repoRoot?,
 *            maxBufferRows? }
 */
export async function runOwnershipResizeStress(browser, options) {
  const {
    baseUrl,
    outputDir,
    phase,
    binaryPrefix = [],
    app,
    repoRoot = process.cwd(),
    maxBufferRows = OWN.maxBufferRows,
  } = options;
  if (!OWN.phases.includes(phase))
    throw new Error(
      `[ownership] phase must be one of ${OWN.phases.join(' / ')}: it is the caller's own label for the build under test, this driver invents no timestamp for it. Got ${JSON.stringify(phase)}`,
    );
  // Every element is an argv string and is shell quoted at launch; a
  // non-string is rejected here rather than silently coerced, because a
  // coerced number or Path would reach the pty as text the caller never
  // asked to launch.
  if (!Array.isArray(binaryPrefix) || binaryPrefix.some((arg) => typeof arg !== 'string'))
    throw new Error(
      `[ownership] binaryPrefix must be an array of argv strings (a native binary that cannot start inside ttyd's environment needs its real dynamic loader and library path); got ${JSON.stringify(binaryPrefix)}`,
    );
  const dir = resolve(outputDir);
  await mkdir(dir, { recursive: true });
  const markers = markerSet();
  const startedAt = Date.now();
  const markerLine = markerCommand();
  const checkpoints = [];
  const ctx = {
    browser,
    baseUrl,
    outputDir: dir,
    app,
    repoRoot,
    phase,
    binaryPrefix,
    host: new URL(baseUrl).hostname,
    pngPrefix: `own-${phase}`,
    tabPrefix: `own-${phase}`,
    markerCommand: markerLine,
    checkpoints,
    probe: { markers, maxBufferRows: bound(maxBufferRows, OWN.maxBufferRows) },
    startedAt,
  };
  const bodies = {
    repl: replOwnershipBody,
    statusline: statuslineOwnershipBody,
    mix: mixOwnershipBody,
  };
  const scenarios = {};
  const failures = [];
  let crashed = null;
  for (const [name, body] of Object.entries(bodies)) {
    const local = [];
    try {
      scenarios[name] = await runOwnershipScenario(ctx, name, body, local);
    } catch (err) {
      // One scenario losing its tab, its binary or its app must not cost the
      // other one its evidence: record it and go on to the next scenario.
      scenarios[name] = { error: String(err) };
      crashed = crashed ?? err;
    }
    checkpoints.push(...local);
    for (const checkpoint of local)
      for (const check of checkpoint.checks)
        if (!check.ok)
          failures.push(`${checkpoint.scenario}/${checkpoint.name}: ${check.name} — ${check.detail}`);
  }
  const finishedAt = Date.now();
  const report = resolve(dir, `ownership-${phase}-report.json`);
  await writeFile(
    report,
    JSON.stringify(
      {
        recipe: 'runOwnershipResizeStress',
        phase,
        phaseMeaning:
          "the caller's own label for this run ('before' or 'after' the repair); the driver invents no timestamp for it and every PNG and JSON below carries it",
        baseUrl,
        outputDir: dir,
        repoRoot,
        binaryPrefix: ctx.binaryPrefix,
        wide: WIDE,
        narrow: NARROW,
        markers: {
          count: markers.length,
          first: markers[0],
          last: markers.at(-1),
          command: markerLine,
        },
        nativeCapacity: {
          flag: CAPACITY_FLAG,
          meaning:
            'every ownership launch carries --terminal-scrollback-rows=N with N read from THAT tab\'s window.term.options.scrollback, never from a constant of this driver: the examples build Region.TerminalReflow .{.non_cursor_rows=.{.scrollback_rows=N}} from it and stay .none without the argument, so this launch is what puts native reflow on.',
          perScenario: Object.fromEntries(
            Object.entries(scenarios).map(([name, run]) => [
              name,
              run?.capacity ?? { error: 'scenario did not report a capacity' },
            ]),
          ),
          commands: Object.fromEntries(
            Object.entries(scenarios).map(([name, run]) => [name, run?.commands ?? []]),
          ),
        },
        mixedInput: {
          ascii: MIX.ascii,
          asciiColumns: MIX.ascii.length,
          glyph: MIX.glyph,
          glyphs: MIX.glyphs,
          text: MIX.text,
          columns: MIX.columns,
          clipRows: MIX.clipRows,
          meaning:
            'the one typed line the mix scenario carries through a one-row physical clip taken at the WIDE width, an odd-width narrowing while still one row, a widening while still one row, and the height restore. The REPL paints it as ONE row and Buffer.draw clips rather than wraps, so at the narrow width the app holds only the grapheme prefix that fits; the whole line is asserted to survive as the TERMINAL\'s own reflow of the hard row the one-row clip retired (`nativeWrapOf`), which is the only proof the wide source still exists.',
          clipRowsMeaning:
            'the physical terminal height the band is clipped into: the band is input + status = 2 rows and bandHeight(1, 0) is 1, so a 1-row terminal keeps the input row alone. The transition RETIRES the band\'s old first input row — it scrolls out of the 1-row viewport with the status row — and the app repaints the same whole line on the surviving row, so no one-row checkpoint claims a clipped current band, a wrapped input or a parked cursor.',
          wrapOracleMeaning:
            '`nativeWrapOf` at narrow-odd: an ARCHIVED band group (above the live one, visible or scrolled past) must carry the full source re-joined in exactly packedRows(...) physical rows at the MEASURED columns, and every one of those joins must carry the terminal\'s OWN wrap flag. App re-emission of the split clears that flag, so the two checks together prove the wide source survived as a native reflow rather than as rows the driver mistook for it.',
        },
        driverClock: {
          startedAt,
          startedAtIso: new Date(startedAt).toISOString(),
          finishedAt,
          finishedAtIso: new Date(finishedAt).toISOString(),
          elapsedMs: finishedAt - startedAt,
          meaning:
            'this driver process\'s own clock. A checkpoint timestamp is when the driver READ the state, never a claim about which key painted which frame.',
        },
        scenarios,
        checkpoints,
        failures,
        error: crashed ? String(crashed) : null,
      },
      null,
      2,
    ),
  );
  // Contract failures and a crashed scenario are two different pieces of
  // evidence about the same run: when both happened the throw carries both,
  // because a failure list on its own would hide the scenario that never
  // reached its checkpoints.
  if (failures.length || crashed)
    throw new Error(
      `[ownership] ${phase}: ${failures.length} contract failure(s)${crashed ? ` and a scenario crash (${crashed})` : ''}, evidence in ${report}\n - ${failures.join('\n - ')}`,
    );
  return {
    baseUrl,
    outputDir: dir,
    phase,
    wide: WIDE,
    narrow: NARROW,
    report,
    markers,
    scenarios,
    checkpoints,
  };
}

export default runResizeStress;
