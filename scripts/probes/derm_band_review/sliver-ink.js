// SLIVER INK PROBE.
//
// A band edge sitting OUTWARD of its printed slot boundary makes a thin strip of the NEIGHBOUR's
// slot visible on the served document. At 0.2-0.4pp that strip is 2-4 pixels and cannot be judged
// by eye, so this measures it on the ORIGINAL scan instead of squinting at the redaction.
//
// Per scanline in the strip it reports two numbers, the same pair the rule detector uses:
//   run   the LONGEST CONTIGUOUS horizontal dark run, as a fraction of the form width.
//         A printed rule is one unbroken run and scores ~1.0 (or ~0.4 for a mid-slot divider).
//   ink   the fraction of dark pixels on that line.
//
// The two together separate the only cases that matter:
//   ink < ~0.02                 blank paper -- nothing to leak
//   run > 0.8 with high ink     the printed rule itself -- form furniture, not client data
//   moderate ink with LOW run   TEXT, in many short pieces. This is the shape that leaks.
//
// Ink alone cannot do it: a dense line of text inks about as much of the width as a rule does,
// which is the measurement error that made the 2026-08-03 detector fail on a light scan.
//
// Usage: node sliver-ink.js <slivers.json> ; then run sliver-ink-run.js and read the result.
//   slivers.json rows: { k, src, edge, rule, side }
const fs = require('fs');
const rows = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

const body = `async (page) => {
  const ROWS = ${JSON.stringify(rows)};
  await page.goto('about:blank', { waitUntil: 'domcontentloaded' });
  return await page.evaluate(async (ROWS) => {
    const load = src => new Promise((ok, no) => {
      const i = new Image(); i.crossOrigin = 'anonymous';
      i.onload = () => ok(i); i.onerror = () => no(new Error('load fail')); i.src = src;
    });
    const out = [];
    for (const R of ROWS) {
      const rec = { k: R.k, side: R.side, edge: R.edge, rule: R.rule };
      try {
        const img = await load(R.src);
        const W = img.naturalWidth, H = img.naturalHeight;
        const c = document.createElement('canvas'); c.width = W; c.height = H;
        const g = c.getContext('2d', { willReadFrequently: true });
        g.drawImage(img, 0, 0);
        const d = g.getImageData(0, 0, W, H).data;
        const L = new Uint8Array(W * H);
        for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
          const i = (y * W + x) * 4;
          L[y * W + x] = (0.299 * d[i] + 0.587 * d[i+1] + 0.114 * d[i+2]) | 0;
        }
        const x0 = Math.floor(W * 0.02), x1 = Math.floor(W * 0.92), span = x1 - x0;

        // per-column paper level over the roster, exactly as the detector does it
        const cut = new Float32Array(W);
        const yA = Math.round(0.18 * H), yB = Math.round(0.70 * H);
        const col = [];
        for (let x = x0; x < x1; x++) {
          col.length = 0;
          for (let y = yA; y <= yB; y += 2) col.push(L[y * W + x]);
          col.sort((a, b) => a - b);
          const p = col[(col.length * 0.70) | 0];
          cut[x] = p - Math.max(9, p * 0.10);
        }

        const lo = Math.min(R.edge, R.rule), hi = Math.max(R.edge, R.rule);
        const yLo = Math.round(lo / 100 * H), yHi = Math.round(hi / 100 * H);
        rec.image = W + 'x' + H;
        rec.sliver_px = (yHi - yLo);
        rec.lines = [];
        for (let y = yLo; y <= yHi; y++) {
          if (y < 0 || y >= H) continue;
          let best = 0, cur = 0, ink = 0;
          for (let x = x0; x < x1; x++) {
            if (L[y * W + x] < cut[x]) { ink++; cur++; if (cur > best) best = cur; } else cur = 0;
          }
          rec.lines.push({ pct: +((y / H) * 100).toFixed(3),
                           run: +(best / span).toFixed(3), ink: +(ink / span).toFixed(3) });
        }
        // strongest TEXT signal in the strip: appreciable ink WITHOUT a long run
        const textish = rec.lines.filter(l => l.ink > 0.02 && l.run < 0.35);
        rec.text_lines = textish.length;
        rec.max_text_ink = textish.length ? Math.max(...textish.map(l => l.ink)) : 0;
      } catch (e) { rec.error = String(e).slice(0, 80); }
      out.push(rec);
    }
    return out;
  }, ROWS);
}`;

fs.writeFileSync(__dirname + '/sliver-ink-run.js', body);
console.log('wrote sliver-ink-run.js (' + rows.length + ' slivers)');
