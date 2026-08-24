// ANNOTATED RULER, several pages per composite.
//
// Draws, over the roster of each page:
//   green solid   a detected SLOT BOUNDARY          purple dashed  a detected MID-SLOT DIVIDER
//   grey dashed   a detected header/footer bar      red            the band currently SERVED
//   orange dot    the human-placed stamp            blue hairlines a 1pp scale
//
// This is the instrument that has been right every time. The detector supplies the VALUE of a
// rule; looking supplies the judgement about which band is wrong. See the header of
// docs/migrations/2026-08-21_0651 for the four automated scorers that were tried instead.
//
// Usage: node annotate.js <pages.json> <offset> <count> <tag>
// pages.json rows: { dump_folder, pg, src, rules:[{pct,k}], rows:[{code,y0,y1,s,sev1}], top_pct, bottom_pct }
const fs = require('fs');
const all = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const OFFSET = Number(process.argv[3] || 0);
const COUNT = Number(process.argv[4] || 3);
const TAG = process.argv[5] || ('ann-' + String(OFFSET).padStart(2, '0'));

const pages = all.slice(OFFSET, OFFSET + COUNT).map(p => ({
  k: p.dump_folder + ' p' + p.pg,
  src: p.src,
  top: p.top_pct == null ? null : Number(p.top_pct),
  bot: p.bottom_pct == null ? null : Number(p.bottom_pct),
  rules: (p.rules || []).map(r => ({ pct: Number(r.pct), k: r.k })),
  rows: (p.rows || []).map(r => ({
    code: r.code, y0: Number(r.y0), y1: Number(r.y1),
    s: r.s == null ? null : Number(r.s), sev1: !!r.sev1,
  })),
}));

const OUT = (process.env.DERM_RENDER_DIR || 'C:/Users/FRED/AppData/Local/Temp/claude/render')
  .split(String.fromCharCode(92)).join('/');

const body = `async (page) => {
  const PAGES = ${JSON.stringify(pages)};
  await page.goto('about:blank', { waitUntil: 'domcontentloaded' });
  await page.setViewportSize({ width: 1320, height: 1400 });
  const log = await page.evaluate(async (PAGES) => {
    const host = document.createElement('div');
    host.id = 'strip';
    host.style.cssText = 'background:#fff;font-family:system-ui,sans-serif';
    document.body.style.margin = '0';
    document.body.appendChild(host);
    const notes = [];

    for (const P of PAGES) {
      const img = new Image(); img.crossOrigin = 'anonymous';
      try { await new Promise((ok, no) => { img.onload = ok; img.onerror = () => no(new Error('x')); img.src = P.src; }); }
      catch (e) { notes.push(P.k + ': IMAGE FAILED'); continue; }

      const ys = P.rows.flatMap(r => [r.y0, r.y1]).concat(P.rules.map(r => r.pct));
      const Y0 = Math.max(0, Math.min(...ys) - 2.5);
      const Y1 = Math.min(100, Math.max(...ys) + 2.5);
      const CW = 1180, XL = 0.02, XR = 0.95;
      const scale = CW / (img.naturalWidth * (XR - XL));
      const H = img.naturalHeight * scale;
      const top = img.naturalHeight * Y0 / 100 * scale;
      const cropH = Math.round(img.naturalHeight * (Y1 - Y0) / 100 * scale);

      const head = document.createElement('div');
      head.textContent = P.k + '     green = slot boundary,  purple = mid-slot divider,  grey = header/footer bar,  red = served band';
      head.style.cssText = 'font:700 13px system-ui;padding:5px 8px;background:#111;color:#fff';
      host.appendChild(head);

      const box = document.createElement('div');
      box.style.cssText = 'position:relative;width:' + (CW + 56) + 'px;height:' + cropH
        + 'px;overflow:hidden;background:#fff;border-bottom:3px solid #111';
      const win = document.createElement('div');
      win.style.cssText = 'position:absolute;left:56px;top:0;width:' + CW + 'px;height:' + cropH + 'px;overflow:hidden';
      const el = document.createElement('img');
      el.src = P.src;
      el.style.cssText = 'position:absolute;left:' + (-img.naturalWidth * XL * scale) + 'px;top:' + (-top)
        + 'px;width:' + (img.naturalWidth * scale) + 'px;height:' + H + 'px';
      win.appendChild(el); box.appendChild(win);
      if (!el.complete) await new Promise(r => { el.onload = r; el.onerror = r; });
      if (el.decode) { try { await el.decode(); } catch (e) {} }

      const Y = v => (v / 100 * H) - top;

      for (let v = Math.ceil(Y0); v <= Y1; v++) {
        const d = document.createElement('div');
        d.style.cssText = 'position:absolute;left:0;right:0;top:' + Y(v) + 'px;height:0;border-top:1px solid rgba(0,140,190,.25)';
        box.appendChild(d);
        const t = document.createElement('div');
        t.textContent = v;
        t.style.cssText = 'position:absolute;left:2px;top:' + (Y(v) - 7) + 'px;font:700 11px system-ui;color:#0088be';
        box.appendChild(t);
      }

      for (const r of P.rules) {
        const boundary = r.k === 'boundary';
        const col = boundary ? '#00a000' : (r.k === 'divider' ? '#a000a0' : '#999');
        const d = document.createElement('div');
        d.style.cssText = 'position:absolute;left:56px;right:0;top:' + Y(r.pct) + 'px;height:0;border-top:'
          + (boundary ? '2px solid ' : '2px dashed ') + col;
        box.appendChild(d);
        const t = document.createElement('div');
        t.textContent = (boundary ? 'B ' : r.k === 'divider' ? 'd ' : 'bar ') + r.pct;
        t.style.cssText = 'position:absolute;right:2px;top:' + (Y(r.pct) - 13) + 'px;font:700 10px system-ui;color:#fff;background:'
          + col + ';padding:0 3px;border-radius:2px';
        box.appendChild(t);
      }

      for (const r of P.rows) {
        const col = r.sev1 ? '#e01e1e' : 'rgba(224,30,30,.45)';
        for (const pair of [[r.y0, 'TOP'], [r.y1, 'BOT']]) {
          const d = document.createElement('div');
          d.style.cssText = 'position:absolute;left:56px;right:0;top:' + Y(pair[0]) + 'px;height:0;border-top:2px solid ' + col;
          box.appendChild(d);
        }
        const t = document.createElement('div');
        t.textContent = r.code + '  ' + r.y0 + ' - ' + r.y1 + (r.sev1 ? '  <<' : '');
        t.style.cssText = 'position:absolute;left:60px;top:' + (Y(r.y0) + 1) + 'px;font:700 11px system-ui;color:#fff;background:'
          + col + ';padding:1px 5px;border-radius:3px';
        box.appendChild(t);
        if (r.s != null) {
          const dot = document.createElement('div');
          dot.style.cssText = 'position:absolute;left:50%;top:' + (Y(r.s) - 5) + 'px;width:11px;height:11px;'
            + 'border-radius:50%;background:#ff8a00;border:2px solid #fff';
          box.appendChild(dot);
        }
      }
      host.appendChild(box);
      notes.push(P.k + ': ' + P.rules.length + ' rules, ' + P.rows.length + ' bands');
    }
    return notes;
  }, PAGES);

  await page.locator('#strip').screenshot({ path: '${OUT}' + '/${TAG}.png' });
  return '${TAG}.png\\n' + log.join('\\n');
}`;

fs.writeFileSync(__dirname + '/annotate-run.js', body);
console.log('wrote annotate-run.js -> ' + TAG + '.png  (' + pages.map(p => p.k).join(', ') + ')');
