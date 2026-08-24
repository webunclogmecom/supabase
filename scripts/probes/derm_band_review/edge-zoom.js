// EDGE ZOOM on a SERVED redacted document.
//
// A band edge that sits OUTWARD of its printed slot boundary lets a sliver of the NEIGHBOUR's slot
// through. The slivers that matter here are fractions of a percentage point -- 0.334pp is about two
// pixels on a 724px scan -- which is far too small to judge on a whole-page render, and far too
// large to wave through: the confirmed 226-JER leak was 1.665pp and showed two thirds of an address
// line.
//
// So this magnifies the strip around each edge OF THE DOCUMENT THE CUSTOMER IS ACTUALLY SERVED.
// Above the top edge and below the bottom edge the page must be solid black. Any ink there is the
// neighbour's, and it is a leak.
//
// Renders into the session scratchpad, NEVER the repo: these are served client documents.
//
// Usage: node edge-zoom.js <edges.json> <tag>
//   edges.json rows: { k, src, y0, y1, rule_top, rule_bot }
const fs = require('fs');
const rows = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const TAG = process.argv[3] || 'edge-zoom';

const OUT = (process.env.DERM_RENDER_DIR || 'C:/Users/FRED/AppData/Local/Temp/claude/render')
  .split(String.fromCharCode(92)).join('/');

const body = `async (page) => {
  const ROWS = ${JSON.stringify(rows)};
  const RENDER_WINDOW = ${Number(process.env.EZ_WINDOW || 3.0)}, RENDER_ZOOM = ${Number(process.env.EZ_ZOOM || 5.5)};
  await page.goto('about:blank', { waitUntil: 'domcontentloaded' });
  await page.setViewportSize({ width: 1300, height: 1500 });
  const log = await page.evaluate(async ([ROWS, RENDER_WINDOW, RENDER_ZOOM]) => {
    document.body.style.margin = '0';
    const host = document.createElement('div');
    host.id = 'strip';
    host.style.cssText = 'background:#fff;font-family:system-ui,sans-serif';
    document.body.appendChild(host);
    const notes = [];

    // WINDOW is how much of the page, in percentage points, is shown around each edge.
    const WINDOW = Number(RENDER_WINDOW), ZOOM = Number(RENDER_ZOOM), CW = 1150;

    for (const R of ROWS) {
      const img = new Image(); img.crossOrigin = 'anonymous';
      try { await new Promise((ok, no) => { img.onload = ok; img.onerror = () => no(new Error('x')); img.src = R.src; }); }
      catch (e) { notes.push(R.k + ': IMAGE FAILED'); continue; }

      for (const E of [{ y: R.y0, rule: R.rule_top, lbl: 'TOP' }, { y: R.y1, rule: R.rule_bot, lbl: 'BOTTOM' }]) {
        const outward = E.lbl === 'TOP' ? (E.y < E.rule) : (E.y > E.rule);
        const head = document.createElement('div');
        head.textContent = R.k + '   ' + E.lbl + ' edge ' + E.y + '   nearest printed boundary ' + E.rule
          + '   offset ' + (E.y - E.rule).toFixed(3) + 'pp ' + (outward ? '<<< OUTWARD (toward the neighbour)' : '(inward, crops its own row)');
        head.style.cssText = 'font:700 13px system-ui;padding:5px 8px;background:' + (outward ? '#8b0000' : '#111') + ';color:#fff';
        host.appendChild(head);

        const scale = CW / img.naturalWidth * ZOOM;
        const H = img.naturalHeight * scale;
        const top = img.naturalHeight * (E.y - WINDOW / 2) / 100 * scale;
        const cropH = Math.round(img.naturalHeight * WINDOW / 100 * scale);

        const box = document.createElement('div');
        box.style.cssText = 'position:relative;width:' + CW + 'px;height:' + cropH
          + 'px;overflow:hidden;background:#556;border-bottom:3px solid #111';
        const el = document.createElement('img');
        el.src = R.src;
        el.style.cssText = 'position:absolute;left:0;top:' + (-top) + 'px;width:'
          + (img.naturalWidth * scale) + 'px;height:' + H + 'px;image-rendering:pixelated';
        box.appendChild(el);
        if (!el.complete) await new Promise(r => { el.onload = r; el.onerror = r; });
        if (el.decode) { try { await el.decode(); } catch (e) {} }

        const Y = v => (v / 100 * H) - top;
        const mk = (v, col, txt) => {
          const d = document.createElement('div');
          d.style.cssText = 'position:absolute;left:0;right:0;top:' + Y(v) + 'px;height:0;border-top:2px solid ' + col;
          box.appendChild(d);
          const t = document.createElement('div');
          t.textContent = txt;
          t.style.cssText = 'position:absolute;right:3px;top:' + (Y(v) - 15) + 'px;font:700 11px system-ui;color:#fff;background:'
            + col + ';padding:1px 5px;border-radius:3px';
          box.appendChild(t);
        };
        mk(E.rule, '#00a000', 'printed boundary ' + E.rule);
        mk(E.y, '#ff8a00', 'band edge ' + E.y);
        host.appendChild(box);
      }
      notes.push(R.k + ' ok');
    }
    return notes;
  }, [ROWS, RENDER_WINDOW, RENDER_ZOOM]);

  await page.locator('#strip').screenshot({ path: '${OUT}' + '/${TAG}.png' });
  return '${TAG}.png\\n' + log.join('\\n');
}`;

fs.writeFileSync(__dirname + '/edge-zoom-run.js', body);
console.log('wrote edge-zoom-run.js -> ' + TAG + '.png (' + rows.length + ' bands, 2 edges each)');
