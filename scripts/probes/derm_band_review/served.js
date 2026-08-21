// Render the ACTUAL served redacted documents for one page, cropped to the roster column.
//
// This is the ground truth: the geometry review reasons about bands drawn over the raw
// scan, but what the client opens is this file. Used to settle whether a band boundary
// that sits on a neighbour's address baseline leaves anything readable.
//
// Usage: node build-served.js <urls.json>   where urls.json = [{code,url}, ...]
const fs = require('fs');
const docs = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const TAG = process.argv[3] || 'served';

const OUT = 'C:\\\\Users\\\\FRED\\\\AppData\\\\Local\\\\Temp\\\\claude\\\\C--Users-FRED-Desktop-Virtrify-Yannick-Claude-Supabase\\\\2982e963-15ef-4634-9336-cb0d4dcad2a2\\\\scratchpad\\\\sweep';

const body = `async (page) => {
  const DOCS = ${JSON.stringify(docs)};
  const OUT = '${OUT}';
  await page.setViewportSize({ width: 1240, height: 1400 });
  await page.setContent('<html><body style="margin:0;background:#fff;font-family:system-ui,sans-serif"><div id="strip"></div></body></html>');
  const log = await page.evaluate(async (DOCS) => {
    const host = document.getElementById('strip');
    const notes = [];
    for (const D of DOCS) {
      const img = new Image(); img.crossOrigin = 'anonymous';
      try { await new Promise((ok, no) => { img.onload = ok; img.onerror = () => no(new Error('load')); img.src = D.url; }); }
      catch (e) { notes.push(D.code + ': FAILED'); continue; }

      const yMin = D.y0 == null ? 20 : Math.max(0, D.y0 - 3);
      const yMax = D.y1 == null ? 70 : Math.min(100, D.y1 + 3);
      const CW = 1150;
      const scale = CW / (img.naturalWidth * 0.55);
      const cropH = Math.round(img.naturalHeight * (yMax - yMin) / 100 * scale);

      const head = document.createElement('div');
      head.textContent = 'SERVED to ' + D.code + '   band ' + D.y0 + ' - ' + D.y1;
      head.style.cssText = 'font:700 13px system-ui;padding:4px 8px;background:#0a5;color:#fff';
      host.appendChild(head);

      const box = document.createElement('div');
      box.style.cssText = 'position:relative;width:' + CW + 'px;height:' + cropH + 'px;overflow:hidden;border-bottom:3px solid #111';
      const el = document.createElement('img');
      el.src = D.url;
      el.style.cssText = 'position:absolute;left:0;top:' + (-img.naturalHeight * yMin / 100 * scale) + 'px;'
        + 'width:' + (img.naturalWidth * scale) + 'px;height:' + (img.naturalHeight * scale) + 'px';
      box.appendChild(el);
      if (!el.complete) await new Promise(r => { el.onload = r; el.onerror = r; });
      if (el.decode) { try { await el.decode(); } catch (e) {} }
      host.appendChild(box);
      notes.push(D.code + ': ' + img.naturalWidth + 'x' + img.naturalHeight);
    }
    return notes;
  }, DOCS);
  await page.locator('#strip').screenshot({ path: OUT + '\\\\${TAG}.png' });
  return '${TAG}.png\\n' + log.join('\\n');
}`;

fs.writeFileSync(__dirname + '/served-run.js', body);
console.log('wrote served-run.js for ' + docs.length + ' documents -> ' + TAG + '.png');
