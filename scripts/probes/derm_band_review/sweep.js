// Batch renderer for the visual review sweep.
//
// Renders a CROPPED ROSTER STRIP per page rather than the whole sheet: only the band
// region plus a margin, and only x 0-55% (the roster column). That is where every
// client's facility name and address is printed, so it carries all the information the
// review needs at roughly 2x the effective zoom of a full-sheet render.
//
// Several pages are stacked into one composite, and several composites are produced by
// ONE browser run, so the sweep costs ~5 tool calls per 15 pages instead of 3 per 4.
//
// The question being answered for each page, by eye:
//   does any band's edge cut across a printed line belonging to a DIFFERENT client?
//
// A band that clips the BOTTOM of its OWN address line is the normal shape of this form
// (the printed slot rule sits within a pixel or two of the address baseline) and is not
// a finding. A whole extra NAME or ADDRESS line inside a band is.
//
// Usage: node build-sweep.js <offset> <total> [perComposite=5]
// Output goes to the scratchpad. These scans carry multi-client PII and the repo is PUBLIC.
const fs = require('fs');
const all = JSON.parse(fs.readFileSync(__dirname + '/sweep-queue.json', 'utf8'));
const done = JSON.parse(fs.readFileSync(__dirname + '/reviewed.json', 'utf8'));
const queue = all.filter(p => !done.includes(p.dump_folder + '#' + p.pg));

const OFFSET = Number(process.argv[2] || 0);
const TOTAL = Number(process.argv[3] || 15);
const PER = Number(process.argv[4] || 5);
const slice = queue.slice(OFFSET, OFFSET + TOTAL);

const norm = (p) => ({
  k: p.dump_folder + '#' + p.pg,
  src: p.src,
  rows: (typeof p.rows === 'string' ? JSON.parse(p.rows) : p.rows).map(r => ({
    code: r.code, y0: Number(r.y0), y1: Number(r.y1),
    s: r.s == null ? null : Number(r.s), served: r.served !== false,
  })),
});

const composites = [];
for (let i = 0; i < slice.length; i += PER) {
  composites.push({
    tag: 'r' + String(OFFSET + i).padStart(3, '0'),
    pages: slice.slice(i, i + PER).map(norm),
  });
}

const OUT = 'C:\\\\Users\\\\FRED\\\\AppData\\\\Local\\\\Temp\\\\claude\\\\C--Users-FRED-Desktop-Virtrify-Yannick-Claude-Supabase\\\\2982e963-15ef-4634-9336-cb0d4dcad2a2\\\\scratchpad\\\\sweep';

const body = `async (page) => {
  const COMPOSITES = ${JSON.stringify(composites)};
  const OUT = '${OUT}';
  await page.setViewportSize({ width: 1240, height: 1400 });
  const log = [];

  for (const C of COMPOSITES) {
    await page.setContent('<html><body style="margin:0;background:#fff;font-family:system-ui,sans-serif"><div id="strip"></div></body></html>');
    const notes = await page.evaluate(async (PAGES) => {
      const host = document.getElementById('strip');
      const notes = [];
      for (const P of PAGES) {
        const img = new Image(); img.crossOrigin = 'anonymous';
        try { await new Promise((ok, no) => { img.onload = ok; img.onerror = () => no(new Error('load')); img.src = P.src; }); }
        catch (e) { notes.push(P.k + ': IMAGE FAILED'); continue; }

        const yMin = Math.max(0, Math.min(...P.rows.map(r => r.y0)) - 4);
        const yMax = Math.min(100, Math.max(...P.rows.map(r => r.y1)) + 4);
        const CW = 1150;                              // composite width
        const scale = CW / (img.naturalWidth * 0.55); // crop x to 0-55%, scaled to fill
        const cropH = Math.round(img.naturalHeight * (yMax - yMin) / 100 * scale);

        const head = document.createElement('div');
        head.textContent = P.k + '   bands: ' + P.rows.map(r => r.code + (r.served ? '' : '*') + ' ' + r.y0.toFixed(1) + '-' + r.y1.toFixed(1)).join('   ');
        head.style.cssText = 'font:700 13px system-ui;padding:4px 8px;background:#111;color:#fff';
        host.appendChild(head);

        const box = document.createElement('div');
        box.style.cssText = 'position:relative;width:' + CW + 'px;height:' + cropH + 'px;overflow:hidden;border-bottom:3px solid #111';
        const el = document.createElement('img');
        el.src = P.src;
        el.style.cssText = 'position:absolute;left:0;top:' + (-img.naturalHeight * yMin / 100 * scale) + 'px;'
          + 'width:' + (img.naturalWidth * scale) + 'px;height:' + (img.naturalHeight * scale) + 'px';
        box.appendChild(el);
        if (!el.complete) await new Promise(r => { el.onload = r; el.onerror = r; });
        if (el.decode) { try { await el.decode(); } catch (e) {} }

        const H = img.naturalHeight * scale;
        const off = img.naturalHeight * yMin / 100 * scale;
        for (const r of P.rows) {
          const top = r.y0 / 100 * H - off, hgt = (r.y1 - r.y0) / 100 * H;
          const b = document.createElement('div');
          b.style.cssText = 'position:absolute;left:0;right:0;top:' + top + 'px;height:' + hgt + 'px;'
            + 'border-top:2px solid ' + (r.served ? '#e01e1e' : '#1663d8') + ';'
            + 'border-bottom:2px solid ' + (r.served ? '#e01e1e' : '#1663d8') + ';'
            + 'background:' + (r.served ? 'rgba(224,30,30,.07)' : 'rgba(22,99,216,.07)') + ';box-sizing:border-box';
          box.appendChild(b);
          const t = document.createElement('div');
          t.textContent = r.code + (r.served ? '' : '*');
          t.style.cssText = 'position:absolute;left:1px;top:' + (top + 1) + 'px;font:700 11px system-ui;'
            + 'color:#fff;background:' + (r.served ? '#e01e1e' : '#1663d8') + ';padding:0 4px;border-radius:2px';
          box.appendChild(t);
          if (r.s != null) {
            const dot = document.createElement('div');
            dot.style.cssText = 'position:absolute;left:52%;top:' + (r.s / 100 * H - off - 4) + 'px;'
              + 'width:9px;height:9px;border-radius:50%;background:#ff8a00;border:2px solid #fff';
            box.appendChild(dot);
          }
        }
        host.appendChild(box);
        notes.push(P.k + ': ' + P.rows.length + ' bands');
      }
      return notes;
    }, C.pages);

    await page.locator('#strip').screenshot({ path: OUT + '\\\\batch-' + C.tag + '.png' });
    log.push('batch-' + C.tag + '.png  ' + notes.join(' | '));
  }
  return log.join('\\n');
}`;

fs.writeFileSync(__dirname + '/sweep-run.js', body);
console.log('remaining ' + queue.length + ' pages; rendering offset ' + OFFSET + ', ' + slice.length + ' pages, ' + composites.length + ' composites -> sweep-run.js');
composites.forEach(c => console.log('   batch-' + c.tag + ': ' + c.pages.map(p => p.k).join(', ')));
