// xterm.js (ttyd) driver for notui visual testing: interactive probes that
// read the emulator's own buffer, cells and raw bytes.
// Usage from an eval JS cell, repo root as cwd:
//   const D = await import(`${process.cwd()}/examples/term_driver.js`);
//   const tab = await browser.open({ name: 'x', url: 'http://127.0.0.1:PORT',
//     app: { relay: false, tern: false }, viewport: { width: 1000, height: 640 }, timeout: 120 });
//   const t = D.driver(tab, '/abs/output/dir');
//   await t.hook();                       // once per page load: records term.write bytes
//   await t.send('ls\r');                 // bytes into the pty (as typed)
//   await t.screen();                     // visible rows as strings
//   await t.cells(row)                    // per-cell {ch,w,fg,bg,bold,inverse,...} of a visible row
//   await t.shot('name');                 // .webp of the terminal canvas -> outDir/name.webp
//   await t.resize(w, h);                 // change viewport px; xterm refits and ttyd sends SIGWINCH
//   await t.recStart(); ...; await t.recStop()  // raw bytes the app wrote (string)

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export function vis(s) {
  return s.replace(/\x1b/g, '⎋').replace(/\r/g, '␍').replace(/\n/g, '␊\n').replace(/\x07/g, '␇');
}

export function driver(tab, outDir) {
  const ev = (code) => tab.evaluate(code);
  const t = {
    tab,
    outDir,
    ev,
    async hook() {
      return ev(`(() => { const t = window.term; if (!t.__orig) { t.__orig = t.write.bind(t); t.__log = []; t.write = (d, cb) => { if (t.__rec) t.__log.push(typeof d === 'string' ? d : new TextDecoder().decode(d)); return t.__orig(d, cb); }; } return true; })()`);
    },
    recStart: () => ev(`(window.term.__log = [], window.term.__rec = true)`),
    async recStop() {
      await ev(`window.term.__rec = false`);
      return ev(`window.term.__log.join('')`);
    },
    send: (s) => ev(`window.term.input(${JSON.stringify(s)}, true)`),
    // Type text one key at a time with a gap (exercises per-key frames).
    async type(s, gapMs = 15) {
      for (const ch of Array.from(s)) {
        await t.send(ch);
        await sleep(gapMs);
      }
    },
    info: () => ev(`(() => { const t = window.term, b = t.buffer.active; return { cols: t.cols, rows: t.rows, cx: b.cursorX, cy: b.cursorY, baseY: b.baseY, viewportY: b.viewportY, length: b.length, cursorHidden: !!t._core?.coreService?.isCursorHidden }; })()`),
    screen: () => ev(`(() => { const t = window.term, b = t.buffer.active, o = []; for (let y = 0; y < t.rows; y++) { const l = b.getLine(b.viewportY + y); o.push(l ? l.translateToString(true) : ''); } return o; })()`),
    // Whole buffer including scrollback.
    buffer: () => ev(`(() => { const t = window.term, b = t.buffer.active, o = []; for (let y = 0; y < b.length; y++) { const l = b.getLine(y); o.push(l ? l.translateToString(true) : ''); } return o; })()`),
    // Per-cell attributes of visible row `row` (0-based). Colors: mode/value.
    cells: (row) => ev(`(() => { const t = window.term, b = t.buffer.active, l = b.getLine(b.viewportY + ${row}); if (!l) return []; const o = []; const c = b.getNullCell(); for (let x = 0; x < t.cols; x++) { l.getCell(x, c); o.push({ x, ch: c.getChars(), w: c.getWidth(), fg: c.isFgDefault() ? 'd' : (c.isFgRGB() ? '#' + c.getFgColor().toString(16).padStart(6, '0') : c.getFgColor()), bg: c.isBgDefault() ? 'd' : (c.isBgRGB() ? '#' + c.getBgColor().toString(16).padStart(6, '0') : c.getBgColor()), bold: !!c.isBold(), dim: !!c.isDim(), italic: !!c.isItalic(), ul: !!c.isUnderline(), inv: !!c.isInverse() }); } return o; })()`),
    async shot(name) {
      const img = await tab.screenshot({ selector: '.xterm-screen', silent: true });
      const p = `${outDir}/${name}.webp`;
      await Bun.$`mv ${img} ${p}`;
      return p;
    },
    async resize(w, h, settleMs = 500) {
      await tab.emulate({ viewport: { width: w, height: h } });
      await sleep(settleMs);
      return t.info();
    },
    // Wait until the visible screen satisfies pred(lines) or timeout.
    async waitScreen(pred, timeoutMs = 5000) {
      const end = Date.now() + timeoutMs;
      let s;
      while (Date.now() < end) {
        s = await t.screen();
        if (pred(s)) return s;
        await sleep(100);
      }
      return null;
    },
  };
  return t;
}
