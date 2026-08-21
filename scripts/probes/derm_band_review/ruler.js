// RULER VIEW - read the correct band boundaries straight off the paper.
//
// Renders one page's roster column at high zoom with a y-scale in page-percent: a tick
// every 0.25pp, a labelled line every 1pp, and the CURRENT bands drawn in red. The gaps
// between printed slots are then directly readable, so a repair value is measured rather
// than inferred from a rule detector.
//
// Built because three automated instruments have failed on this question in a row
// (distance to the nearest detected rule; counting text lines inside a band; gap from the
// black box edge to the first ink on the served document). None separated a confirmed leak
// from a confirmed clean band. Looking at the paper has been right every time.
//
// Usage: node build-ruler.js "<dump_folder>#<page>" [y_from] [y_to]
const fs = require('fs');
const queue = JSON.parse(fs.readFileSync(__dirname + '/sweep-queue.json', 'utf8'));
const key = process.argv[2];
const page = queue.find(p => p.dump_folder + '#' + p.pg === key);
if (!page) { console.error('page not found: ' + key); process.exit(1); }

const yFrom = process.argv[3] ? Number(process.argv[3]) : Math.min(...page.rows.map(r => r.y0)) - 2;
const yTo = process.argv[4] ? Number(process.argv[4]) : Math.max(...page.rows.map(r => r.y1)) + 2;

const OUT = 'C:\\\\Users\\\\FRED\\\\AppData\\\\Local\\\\Temp\\\\claude\\\\C--Users-FRED-Desktop-Virtrify-Yannick-Claude-Supabase\\\\2982e963-15ef-4634-9336-cb0d4dcad2a2\\\\scratchpad\\\\sweep';
const TAG = 'ruler-' + key.replace(/[#/]/g, '-');

const body = `async (page) => {
  const P = ${JSON.stringify({ k: key, src: page.src, rows: page.rows })};
  const Y0 = ${yFrom}, Y1 = ${yTo};
  const OUT = '${OUT}';
  await page.setViewportSize({ width: 1300, height: 1500 });
  await page.setContent('<html><body style="margin:0;background:#fff;font-family:system-ui,sans-serif"><div id="sheet"></div></body></html>');
  const note = await page.evaluate(async (args) => {
    const { P, Y0, Y1 } = args;
    const host = document.getElementById('sheet');
    const img = new Image(); img.crossOrigin = 'anonymous';
    await new Promise((ok, no) => { img.onload = ok; img.onerror = no; img.src = P.src; });

    const CW = 1180;                                // width of the rendered roster column
    const XL = 0.04, XR = 0.50;                     // page x window
    const scale = CW / (img.naturalWidth * (XR - XL));
    const H = img.naturalHeight * scale;
    const top = img.naturalHeight * Y0 / 100 * scale;
    const cropH = Math.round(img.naturalHeight * (Y1 - Y0) / 100 * scale);

    const box = document.createElement('div');
    box.id = 'box';
    box.style.cssText = 'position:relative;width:' + (CW + 62) + 'px;height:' + cropH + 'px;overflow:hidden;background:#fff';
    const win = document.createElement('div');
    win.style.cssText = 'position:absolute;left:62px;top:0;width:' + CW + 'px;height:' + cropH + 'px;overflow:hidden';
    const el = document.createElement('img');
    el.src = P.src;
    el.style.cssText = 'position:absolute;left:' + (-img.naturalWidth * XL * scale) + 'px;top:' + (-top) + 'px;'
      + 'width:' + (img.naturalWidth * scale) + 'px;height:' + H + 'px';
    win.appendChild(el);
    box.appendChild(win);
    if (!el.complete) await new Promise(r => { el.onload = r; el.onerror = r; });
    if (el.decode) { try { await el.decode(); } catch (e) {} }

    for (let v = Math.ceil(Y0 * 4) / 4; v <= Y1; v += 0.25) {
      const y = (v / 100 * H) - top;
      const whole = Math.abs(v - Math.round(v)) < 1e-6;
      const d = document.createElement('div');
      d.style.cssText = 'position:absolute;left:' + (whole ? 0 : 44) + 'px;right:0;top:' + y + 'px;height:0;'
        + 'border-top:1px solid rgba(0,140,190,' + (whole ? '.55' : '.28') + ')';
      box.appendChild(d);
      if (whole) {
        const t = document.createElement('div');
        t.textContent = v.toFixed(0);
        t.style.cssText = 'position:absolute;left:2px;top:' + (y - 7) + 'px;font:700 11px system-ui;color:#0088be';
        box.appendChild(t);
      }
    }

    for (const r of P.rows) {
      for (const [v, lab] of [[r.y0, r.code + ' top ' + r.y0], [r.y1, r.code + ' bot ' + r.y1]]) {
        const y = (v / 100 * H) - top;
        const d = document.createElement('div');
        d.style.cssText = 'position:absolute;left:62px;right:0;top:' + y + 'px;height:0;border-top:1.5px solid rgba(224,30,30,.9)';
        box.appendChild(d);
        const t = document.createElement('div');
        t.textContent = lab;
        t.style.cssText = 'position:absolute;right:2px;top:' + (y - 13) + 'px;font:700 10px system-ui;color:#fff;background:#e01e1e;padding:0 3px;border-radius:2px';
        box.appendChild(t);
      }
    }
    host.appendChild(box);
    return P.k + '  ' + Y0 + ' to ' + Y1 + 'pp, ' + P.rows.length + ' bands';
  }, { P, Y0, Y1 });

  await page.locator('#box').screenshot({ path: OUT + '\\\\${TAG}.png' });
  return '${TAG}.png  ' + note;
}`;

fs.writeFileSync(__dirname + '/ruler-run.js', body);
console.log('wrote ruler-run.js -> ' + TAG + '.png  (' + yFrom.toFixed(2) + ' to ' + yTo.toFixed(2) + 'pp)');
