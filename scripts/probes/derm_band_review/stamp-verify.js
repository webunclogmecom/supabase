// STAMP PLACEMENT VERIFIER.
//
// Renders one sheet image with every AI/human stamp drawn at its stored (stamp_x_pct, stamp_y_pct),
// labelled with the client code, so a person can confirm the stamp sits on that client's own
// printed row. This is the visual half of the auto-stamp check: the gate proves the row READER
// agrees with the slot map, and this proves the resulting GEOMETRY lands where it should.
//
// Renders into the session scratchpad, NEVER the repo: a sheet image carries several clients'
// names and addresses.
//
// Usage: node stamp-verify.js <spec.json> <tag>
//   spec.json: { src, title, stamps:[{code, x, y}], rules:[pct] }
const fs = require('fs');
const spec = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const TAG = process.argv[3] || 'stamp-verify';

const OUT = 'C:\\\\Users\\\\FRED\\\\AppData\\\\Local\\\\Temp\\\\claude\\\\'
  + 'C--Users-FRED-Desktop-Virtrify-Yannick-Claude-Supabase\\\\'
  + '2bd7bc4d-8da1-406f-9078-39e5d38a6813\\\\scratchpad';

const body = `async (page) => {
  const S = ${JSON.stringify(spec)};
  await page.goto('about:blank', { waitUntil: 'domcontentloaded' });
  await page.setViewportSize({ width: 1320, height: 1500 });
  const log = await page.evaluate(async (S) => {
    document.body.style.margin = '0';
    const host = document.createElement('div');
    host.id = 'strip';
    host.style.cssText = 'background:#fff;font-family:system-ui,sans-serif';
    document.body.appendChild(host);

    const img = new Image(); img.crossOrigin = 'anonymous';
    await new Promise((ok, no) => { img.onload = ok; img.onerror = () => no(new Error('load')); img.src = S.src; });

    const CW = 1240;
    const scale = CW / img.naturalWidth;
    const H = img.naturalHeight * scale;

    const head = document.createElement('div');
    head.textContent = S.title + '   (orange = stamp at its stored x/y, blue = 1pp scale)';
    head.style.cssText = 'font:700 13px system-ui;padding:6px 8px;background:#111;color:#fff';
    host.appendChild(head);

    const box = document.createElement('div');
    box.style.cssText = 'position:relative;width:' + (CW + 46) + 'px;height:' + H + 'px;background:#fff';
    const el = document.createElement('img');
    el.src = S.src;
    el.style.cssText = 'position:absolute;left:46px;top:0;width:' + CW + 'px;height:' + H + 'px';
    box.appendChild(el);
    if (!el.complete) await new Promise(r => { el.onload = r; el.onerror = r; });
    if (el.decode) { try { await el.decode(); } catch (e) {} }

    const Y = v => v / 100 * H;

    for (let v = 0; v <= 100; v += 2) {
      const d = document.createElement('div');
      d.style.cssText = 'position:absolute;left:0;right:0;top:' + Y(v) + 'px;height:0;border-top:1px solid rgba(0,140,190,.22)';
      box.appendChild(d);
      const t = document.createElement('div');
      t.textContent = v;
      t.style.cssText = 'position:absolute;left:3px;top:' + (Y(v) - 7) + 'px;font:700 10px system-ui;color:#0088be';
      box.appendChild(t);
    }

    for (const r of (S.rules || [])) {
      const d = document.createElement('div');
      d.style.cssText = 'position:absolute;left:46px;right:0;top:' + Y(r) + 'px;height:0;border-top:2px solid rgba(0,160,0,.55)';
      box.appendChild(d);
    }

    for (const s of S.stamps) {
      const left = 46 + (s.x / 100 * CW);
      const dot = document.createElement('div');
      dot.style.cssText = 'position:absolute;left:' + (left - 8) + 'px;top:' + (Y(s.y) - 8)
        + 'px;width:16px;height:16px;border-radius:50%;background:#ff8a00;border:3px solid #fff;box-shadow:0 0 0 2px #ff8a00';
      box.appendChild(dot);
      const line = document.createElement('div');
      line.style.cssText = 'position:absolute;left:46px;right:0;top:' + Y(s.y) + 'px;height:0;border-top:2px dashed rgba(255,138,0,.85)';
      box.appendChild(line);
      const t = document.createElement('div');
      t.textContent = s.code + '  y=' + s.y;
      t.style.cssText = 'position:absolute;left:' + (left + 14) + 'px;top:' + (Y(s.y) - 9)
        + 'px;font:700 13px system-ui;color:#fff;background:#ff8a00;padding:1px 6px;border-radius:3px';
      box.appendChild(t);
    }

    host.appendChild(box);
    return S.stamps.length + ' stamps drawn on a ' + img.naturalWidth + 'x' + img.naturalHeight + ' image';
  }, S);

  await page.locator('#strip').screenshot({ path: '${OUT}' + '\\\\${TAG}.png' });
  return '${TAG}.png -- ' + log;
}`;

fs.writeFileSync(__dirname + '/stamp-verify-run.js', body);
console.log('wrote stamp-verify-run.js -> ' + TAG + '.png');
