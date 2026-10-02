// notui bounded-region capture driver — the declared native retention
// capacity measured against the real terminal's own scrollback. It drives
// the real example-bounded-smoke binary through a real ttyd pty in a real
// Chromium tab and resizes the REAL viewport (xterm.js FitAddon ->
// RESIZE_TERMINAL -> TIOCSWINSZ -> real SIGWINCH). It never judges a
// picture: every checkpoint records the whole real buffer next to the
// invariant the parent should look for, and it starts no service of its
// own.
//
// THE QUESTION: examples/bounded_smoke.zig opts into
// `Region.TerminalReflow .{.non_cursor_rows = .{.scrollback_rows = N}}`.
// This recipe varies N per case, types the app into a tab whose scrollback
// it has just set to that same N, and then checks what the region kept:
//   - the committed history (98 `hNN` rows) survives a physical height
//     cycle exactly once each, all 98 with a 100- or 200-row capacity and
//     none at all with `capacity = 0`;
//   - no owned glyph residue (`a`, `界`) anywhere in the buffer after the
//     partial erase and the height restore;
//   - the app's prehistory rows (`PNN`, printed above the region before
//     its first frame) are untouched throughout;
//   - exactly one `T` status row at the final checkpoint;
//   - the app exits 0, through the launcher's own rc marker.
// It also pins what the capacity really did at the moment the band was
// erased one row at a time: the retained prefix of the retired input row,
// 33 rows at 3 columns with capacity 100 and 23 with capacity 200.
//
// THREE CASES, one fresh pty and tab each, in the same order every run:
//   bounded-100-0   capacity 100, no prehistory
//   bounded-200-10  capacity 200, 10 prehistory rows
//   bounded-0-0     capacity 0 (a terminal that keeps no scrollback)
//
// DECLARED NATIVE CAPACITY is READ BACK, never assumed: each case sets
// `window.term.options.scrollback` to its own N in the page main world,
// fits the tab, and fails hard if the terminal's own capacity is not the
// N the app is about to be launched with. The exact command typed is
// recorded in that case's report.
//
// ttyd, started by the parent in the devenv shell (repo root as cwd):
//   ttyd -i 127.0.0.1 -p 7681 -W -t rendererType=canvas \
//     -t 'fontFamily="DejaVu Sans Mono"' -t fontSize=16 -t lineHeight=1.2 \
//     -t cursorBlink=false -t disableResizeOverlay=true \
//     -t disableLeaveAlert=true -t disableReconnect=true \
//     -t titleFixed=notui-bounded bash --noprofile --norc
// No -o/--once and no -q/--exit-no-conn: one tab per case means one fresh
// pty each, and either flag would kill the server on the first disconnect.
// rendererType=canvas is ttyd's no-WebGL fallback; disableResizeOverlay
// keeps its 300ms "COLSxROWS" overlay out of the frames. The driver sets
// the scrollback per tab, so ttyd's own -t scrollback is not what the
// capacity cases measure.
//
// ttyd 1.7.7 has no exposeTerm option: Xterm.open() assigns `window.term`
// unconditionally, so the real xterm.js buffer is read from there — no
// fallback, a missing window.term fails the first hard wait. Terminal
// state is read with `tab.evaluate`, the PAGE MAIN WORLD, because that is
// the only world with ttyd's `window.term`: a raw `page.evaluate` inside
// `tab.run` is isolated and reports `window.term === undefined`. The
// isolated world is used only where no page global is needed — the 2-RAF
// resize wait, the real keyboard and screenshot calls.
//
// CDP lifecycle: `app.cdp_url` ATTACHES to a target this module did not
// create, so nothing here creates, closes or serves one. `browser.open`'s
// `viewport` is metadata only on such a target: every geometry is set
// through the page and read back from the main world. The parent owns the
// ttyd service and kills its Chromium.
//
// CHECKPOINTS (8 PNGs + one report.json per case, plus one
// bounded-report.json for the run):
//   bounded-<capacity>-<prehistory>/{initial,narrow-55,committed-98,
//     width-66,height-100-partial-cleanup,width-3,
//     height-150-restored,exit}.png
//
// Eval, JS kernel (no import side effects), from the repo root:
//   const { runBoundedResize } = await import("./examples/bounded_resize.js");
//   display(await runBoundedResize(browser, {
//     baseUrl: "http://127.0.0.1:7681",
//     app: { cdp_url: "http://127.0.0.1:17790" },   // optional
//   }));
//   // then READ every file listed in report.cases[].checkpoints[].file
//   // failures, the binary's sha256 and the per-case checks are in
//   // bounded-report.json even when the call throws
//
// API: runBoundedResize(browser, { baseUrl, app?, binaryPrefix?, binaryPath?,
//   outputDir?, repoRoot?, cases? })
//   browser: the managed handle; baseUrl: the ttyd URL. app: optional
//   browser.open `app` — an endpoint to ATTACH to, never a process or
//   target this module launches. binaryPrefix: optional argv prefix for a
//   native binary that cannot start inside ttyd's environment (a Debug
//   build needs its real dynamic loader and --library-path); every
//   element is shell quoted, and the default is a plain direct launch.
//   binaryPath: defaults to `<repoRoot>/zig-out/bin/example-bounded-smoke`;
//   outputDir: defaults to `<repoRoot>/zig-out/visual/bounded`, created if
//   missing; both are resolved against repoRoot (default cwd()), and an
//   absolute value is used as given. The binaries run by absolute path,
//   so ttyd's cwd is irrelevant. cases? ([100, 0], [200, 10], [0, 0] as
//   [capacity, prehistory] pairs) runs a subset; it only ever removes
//   cases, and `ok` then judges the cases that ran.
//   Returns { binary, cases, ok }, where `binary` is { path, realpath,
//   bytes, sha256 } — the SHA-256 of the bytes actually launched — and each
//   case carries { capacity, prehistory, command, exit, error?, checks,
//   checkpoints }, each checkpoint { name, file, cols, rows, capacity,
//   viewport, cell, baseY, cursor, replies, lines } measured rather than
//   assumed. Throws on infrastructure loss; every case's report.json is
//   written before the throw, and a failed case is recorded and the run
//   continues, so one broken terminal never hides the other two.

import { createHash } from 'node:crypto';
import { mkdir, readFile, realpath, stat, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';

// The installed artifact this recipe launches (`zig build` installs every
// example into zig-out/bin).
const BINARY = 'example-bounded-smoke';

// [scrollback capacity, prehistory rows]. Capacity 0 is a real case: a
// terminal that keeps no scrollback at all.
const CASES = Object.freeze([
  [100, 0],
  [200, 10],
  [0, 0],
]);

const WAIT_POLLS = 120; // hard-wait polls before the run fails
const WAIT_POLL_MS = 100; // 12s of them: a slow first ttyd load, never app output
const FIT_TRIES = 12; // viewport -> refit -> measure, until it really fits
const SETTLE_MS = 700; // bounded settle before a checkpoint is read
const COMMITTED_MS = 900; // the `g` keypress commits 98 history rows

const quote = (s) => `'${String(s).replaceAll("'", `'\\''`)}'`;
const sleep = (ms) => new Promise((resolve_) => setTimeout(resolve_, ms));

/** The real xterm.js state, read from ttyd's `window.term`. */
async function state(tab) {
  return tab.evaluate(() => {
    const t = window.term;
    if (!t?.buffer?.active) return null;
    const b = t.buffer.active;
    const box = document.querySelector('.xterm-screen').getBoundingClientRect();
    return {
      cols: t.cols,
      rows: t.rows,
      capacity: t.options.scrollback,
      viewport: { width: innerWidth, height: innerHeight },
      cell: { width: box.width / t.cols, height: box.height / t.rows },
      baseY: b.baseY,
      cursor: { x: b.cursorX, y: b.cursorY },
      replies: [...(window.__notuiBoundedReplies ?? [])],
      lines: Array.from({ length: b.length }, (_, i) => {
        const line = b.getLine(i);
        const cells = [];
        for (let x = 0; x < t.cols; x++) {
          const c = line.getCell(x);
          if (c.getChars() || c.getWidth() === 0) {
            cells.push({ x, text: c.getChars(), width: c.getWidth() });
          }
        }
        return {
          i,
          y: i - b.baseY,
          wrapped: line.isWrapped,
          text: line.translateToString(true),
          cells,
        };
      }),
    };
  });
}

/** A hard wait on real terminal state; the last observed state is the message. */
async function waitFor(tab, predicate, what) {
  for (let n = 0; n < WAIT_POLLS; n++) {
    const current = await state(tab);
    if (current && predicate(current)) return current;
    await sleep(WAIT_POLL_MS);
  }
  throw new Error(`${what}: ${JSON.stringify(await state(tab))}`);
}

/**
 * The real viewport, resized and refitted until the terminal really is
 * `cols` x `rows`; the measured cell box is what converts a column or row
 * delta into pixels. Never assumes the fit happened.
 */
async function fit(tab, cols, rows) {
  let current = await state(tab);
  for (let n = 0; n < FIT_TRIES; n++) {
    if (current.cols === cols && current.rows === rows) return current;
    const viewport = {
      width: Math.max(
        1,
        Math.round(current.viewport.width + (cols - current.cols) * current.cell.width),
      ),
      height: Math.max(
        1,
        Math.round(current.viewport.height + (rows - current.rows) * current.cell.height),
      ),
    };
    await tab.run(async ({ page }, vp) => {
      await page.setViewport(vp);
      await page.evaluate(
        () => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))),
      );
    }, { args: [viewport] });
    await sleep(250);
    await tab.observe();
    current = await state(tab);
  }
  throw new Error(`Exact fit ${cols}x${rows} failed: ${JSON.stringify(current)}`);
}

/** Type into the real pty, optionally with Enter, through the real keyboard. */
async function key(tab, text, enter = false) {
  await tab.run(async ({ page }, value, submit) => {
    await page.focus('.xterm-helper-textarea');
    await page.keyboard.type(value, { delay: 5 });
    if (submit) await page.keyboard.press('Enter');
  }, { args: [text, enter] });
  await tab.observe();
}

/** Settle, read the real buffer, photograph it. */
async function capture(tab, dir, name) {
  await sleep(SETTLE_MS);
  const current = await state(tab);
  const file = `${dir}/${name}.png`;
  await tab.run(async ({ page }, path) => {
    await page.screenshot({ path, fullPage: false });
  }, { args: [file] });
  return { name, file, ...current };
}

/** The app, its capacity declaration and the launcher's own rc marker. */
const launchCommand = (binAbs, name, capacity, prehistory, prefix) =>
  `${[...prefix, binAbs, `--terminal-scrollback-rows=${capacity}`, `--prehistory=${prehistory}`]
    .map(quote)
    .join(' ')}; rc=$?; printf '\\nBOUND_EXIT ${name} rc=%s\\n' "$rc"`;

/** What was actually launched: the bytes, the real file behind them, their digest. */
async function binaryIdentity(binAbs) {
  let bytes;
  let real;
  let st;
  try {
    [bytes, real, st] = await Promise.all([readFile(binAbs), realpath(binAbs), stat(binAbs)]);
  } catch (err) {
    throw new Error(`[bounded] cannot read the binary to launch (${binAbs}): ${err}`);
  }
  return {
    path: binAbs,
    realpath: real,
    bytes: st.size,
    sha256: createHash('sha256').update(bytes).digest('hex'),
  };
}

/** `h00`..`h97` — the committed-history markers, in the order the app prints them. */
const historyMarkers = (n = 98) =>
  Array.from({ length: n }, (_, i) => `h${String(i).padStart(2, '0')}`);

/** `PNN` — the app's prehistory rows, the buffer the region must never touch. */
const prehistoryMarkers = (n) =>
  Array.from({ length: n }, (_, i) => `P${String(i).padStart(2, '0')}`);

/** Every occurrence of `marker` in the recorded buffer rows. */
const count = (rows, marker) => rows.filter((r) => r === marker).length;

/** A row made only of the app's retired input row (ASCII and width-two glyphs). */
const isOwnedInput = (text) => /^[a界]+$/.test(text);

/**
 * One capacity case: declare the capacity on the tab, launch the app, take
 * the band through a width reflow, a partial erase and a height restore,
 * and check what the region kept. Every checkpoint and every check is
 * written to the case's own report even when the case throws — a failed
 * case is recorded and the run continues.
 */
async function runCase(ctx, capacity, prehistory) {
  const name = `bounded-${capacity}-${prehistory}`;
  const dir = `${ctx.outputDir}/${name}`;
  await mkdir(dir, { recursive: true });
  const tab = await ctx.browser.open({
    name,
    url: ctx.baseUrl,
    headed: false,
    allowed_domains: [ctx.host],
    ...(ctx.app ? { app: ctx.app } : {}),
  });
  const result = { capacity, prehistory, checkpoints: [], checks: [] };
  try {
    await waitFor(tab, (s) => s.cols > 0 && s.rows > 0, 'terminal boot');
    await tab.evaluate(String.raw`(() => {
      window.term.options.scrollback = ${capacity};
      window.__notuiBoundedReplies = [];
      window.__notuiBoundedReplyHook = window.term.onData(data => {
        if (/^\x1b\[\d+;\d+R$/.test(data))
          window.__notuiBoundedReplies.push({ data, at: performance.now() });
      });
    })()`);
    await tab.observe();
    const initial = await fit(tab, 131, 1);
    if (initial.capacity !== capacity) throw new Error('Capacity not applied');
    result.command = launchCommand(
      ctx.binaryPath,
      name,
      initial.capacity,
      prehistory,
      ctx.binaryPrefix,
    );
    await key(tab, result.command, true);
    await waitFor(tab, (s) => s.lines.some((r) => r.text === 'T'), 'first live frame');
    result.checkpoints.push(await capture(tab, dir, 'initial'));
    await fit(tab, 55, 1);
    result.checkpoints.push(await capture(tab, dir, 'narrow-55'));
    await key(tab, 'g');
    await sleep(COMMITTED_MS);
    result.checkpoints.push(await capture(tab, dir, 'committed-98'));
    await fit(tab, 66, 1);
    result.checkpoints.push(await capture(tab, dir, 'width-66'));
    if (capacity > 0) {
      const projected = result.checkpoints.at(-1);
      result.checks.push({
        name: 'partial-prefix-still-retained-at-66',
        ok: projected.lines.some((r) => isOwnedInput(r.text)),
      });
    }
    await fit(tab, 66, 100);
    result.checkpoints.push(await capture(tab, dir, 'height-100-partial-cleanup'));
    await fit(tab, 3, 100);
    result.checkpoints.push(await capture(tab, dir, 'width-3'));
    if (capacity > 0) {
      const projected = result.checkpoints.at(-1);
      const ownedRows = projected.lines.filter((r) => isOwnedInput(r.text)).length;
      const expectedRows = capacity === 100 ? 33 : 23;
      result.checks.push({
        name: 'retained-prefix-exact-after-partial-erase',
        ok: ownedRows === expectedRows,
        observed: ownedRows,
        expected: expectedRows,
      });
    }
    await fit(tab, 3, 150);
    const final = await capture(tab, dir, 'height-150-restored');
    result.checkpoints.push(final);
    const rows = final.lines.map((r) => r.text);
    result.checks.push({
      name: 'no-owned-glyph-residue',
      ok: !rows.some((r) => r.includes('界') || /^a+$/.test(r)),
    });
    // 98 committed markers, each present exactly once with a real capacity
    // and absent without one: `observed` counts the distinct markers left.
    const committed = historyMarkers().filter((marker) => count(rows, marker) > 0);
    const expectedH = capacity === 0 ? 0 : 98;
    result.checks.push({
      name: 'committed-history-retained-exactly-once',
      ok: committed.length === expectedH && committed.every((m) => count(rows, m) === 1),
      observed: committed.length,
      expected: expectedH,
    });
    result.checks.push({ name: 'one-current-T', ok: count(rows, 'T') === 1 });
    result.checks.push({
      name: 'prehistory-preserved',
      ok: prehistoryMarkers(prehistory).every((marker) => count(rows, marker) === 1),
    });
    await key(tab, 'q');
    const exit = await waitFor(
      tab,
      (s) => s.lines.map((r) => r.text).join('').includes(`BOUND_EXIT ${name} rc=`),
      'actual program exit',
    );
    result.exit = exit;
    result.checks.push({
      name: 'exit-zero',
      ok: exit.lines.map((r) => r.text).join('').includes(`BOUND_EXIT ${name} rc=0`),
    });
    result.checkpoints.push(await capture(tab, dir, 'exit'));
  } catch (error) {
    result.error = String(error);
    result.failure = await state(tab);
  } finally {
    await writeFile(`${dir}/report.json`, JSON.stringify(result, null, 2));
    await tab.close();
  }
  return result;
}

/**
 * options: { baseUrl, app?, binaryPrefix?, binaryPath?, outputDir?,
 *            repoRoot?, cases? }
 * @see the header comment for the full contract.
 */
export async function runBoundedResize(browser, options) {
  const {
    baseUrl,
    app,
    binaryPrefix = [],
    binaryPath,
    outputDir = 'zig-out/visual/bounded',
    repoRoot = process.cwd(),
    cases = CASES,
  } = options;
  const dir = resolve(repoRoot, outputDir);
  await mkdir(dir, { recursive: true });
  const ctx = {
    browser,
    baseUrl,
    app,
    binaryPrefix,
    binaryPath: binaryPath ?? resolve(repoRoot, 'zig-out/bin', BINARY),
    outputDir: dir,
    host: new URL(baseUrl).hostname,
  };
  const report = { binary: await binaryIdentity(ctx.binaryPath), cases: [] };
  for (const [capacity, prehistory] of cases) {
    report.cases.push(await runCase(ctx, capacity, prehistory));
  }
  report.ok = report.cases.every((c) => !c.error && c.checks.every((check) => check.ok));
  await writeFile(`${dir}/bounded-report.json`, JSON.stringify(report, null, 2));
  return report;
}
