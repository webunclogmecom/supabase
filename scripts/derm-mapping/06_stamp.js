// 06_stamp.js <positions.json> : stamp each CONFIRMED client code into its GDO# box on the sheet image,
// producing an individual PNG per page grouped by 2-week window. Uncertain rows are left blank.
// positions.json = a pos-workflow result (task-output wraps under .result). Confident rows come from
// derm.address_row_map (assignment_status='matched' AND confidence='high'); a row is placed by matching
// its facility name to the located rows (fallback: same row_index). Only confident rows get a code.
const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const { q } = require('./lib/db');
const OUTROOT = 'C:/Users/FRED/Downloads/DERM_Stamped';
const norm = s => String(s || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
const toks = s => new Set(norm(s).split(' ').filter(t => t.length > 2));
function overlap(a, b) { const A = toks(a), B = toks(b); let n = 0; for (const t of A) if (B.has(t)) n++; return n; }
function jpegSize(b) { let i = 2; while (i < b.length) { if (b[i] !== 0xFF) { i++; continue; } const m = b[i + 1]; if (m >= 0xC0 && m <= 0xCF && m !== 0xC4 && m !== 0xC8 && m !== 0xCC) return { w: b.readUInt16BE(i + 7), h: b.readUInt16BE(i + 5) }; i += 2 + b.readUInt16BE(i + 2); } return null; }
function pngSize(b) { return { w: b.readUInt32BE(16), h: b.readUInt32BE(20) }; }
const chrome = ['C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe', 'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe', (process.env.LOCALAPPDATA || '') + '\\Google\\Chrome\\Application\\chrome.exe'].find(c => fs.existsSync(c));
const HTMLTMP = path.resolve(__dirname, 'data', '_stamp_tmp.html');
function render(imgPath, gdoX, stamps, out) {
  const buf = fs.readFileSync(imgPath);
  const isPng = buf[0] === 0x89 && buf[1] === 0x50;
  const sz = isPng ? pngSize(buf) : jpegSize(buf);
  if (!sz) throw new Error('no dimensions for ' + imgPath);
  const { w, h } = sz, mime = isPng ? 'image/png' : 'image/jpeg', b64 = buf.toString('base64');
  const fsz = Math.round(w * 0.017);
  const labels = stamps.map(s => `<div class="code" style="left:${gdoX}%;top:${s.y_pct}%">${String(s.code).replace(/</g, '')}</div>`).join('');
  const html = `<!doctype html><html><head><meta charset="utf-8"><style>
   *{margin:0;padding:0;box-sizing:border-box}.wrap{position:relative;width:${w}px}img{width:${w}px;display:block}
   .code{position:absolute;color:#d40000;font-weight:800;font-family:Consolas,'Courier New',monospace;font-size:${fsz}px;
     background:rgba(255,255,255,.5);padding:0 2px;transform:translate(-50%,-50%);white-space:nowrap;line-height:1;border-radius:2px}
   </style></head><body><div class="wrap"><img src="data:${mime};base64,${b64}">${labels}</div></body></html>`;
  fs.writeFileSync(HTMLTMP, html);
  cp.execSync(`"${chrome}" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --screenshot="${out}" --window-size=${w},${h} "file:///${HTMLTMP.replace(/\\/g, '/')}"`, { stdio: 'pipe' });
}
(async () => {
  if (!chrome) { console.error('Chrome not found'); process.exit(1); }
  const raw = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const positions = (raw.result && raw.result.positions) || raw.positions || [];
  const db = await q(`SELECT m.dump_folder, m.page, m.row_index, m.facility_name_read, c.client_code AS code
    FROM derm.address_row_map m JOIN clients c ON c.id=m.matched_client_id
    WHERE m.assignment_status='matched' AND m.confidence='high' AND c.client_code IS NOT NULL`);
  const dbByPage = {};
  for (const r of db) { const k = r.dump_folder + '|' + r.page; (dbByPage[k] = dbByPage[k] || []).push(r); }
  let imgs = 0, coded = 0, fails = 0;
  for (const pos of positions) {
    if (!pos || !pos.local_file || String(pos.local_file).startsWith('DL_FAIL')) continue;
    const m = /^w(\d+)-/.exec(pos.label || '');
    const win = m ? String(m[1]).padStart(2, '0') : '00';
    const dir = OUTROOT + '/Window_' + win;
    fs.mkdirSync(dir, { recursive: true });
    const dbrows = dbByPage[pos.dump_folder + '|' + pos.page] || [];
    const usedPos = new Set(), stamps = [];
    for (const d of dbrows) {
      let best = null, bs = 0;
      for (const pr of (pos.rows || [])) { if (usedPos.has(pr)) continue; const sc = overlap(d.facility_name_read, pr.facility_name); if (sc > bs) { bs = sc; best = pr; } }
      if (!best || bs === 0) best = (pos.rows || []).find(pr => pr.row_index === d.row_index && !usedPos.has(pr)) || null;
      if (best && typeof best.y_pct === 'number') { usedPos.add(best); stamps.push({ y_pct: best.y_pct, code: d.code }); }
    }
    const base = pos.wm ? ('ticket_' + pos.wm) : String(pos.dump_folder || 'sheet').replace(/[^a-z0-9]+/gi, '_');
    const out = dir + '/' + base + '_p' + pos.page + (stamps.length ? ('_' + stamps.length + 'codes') : '_blank') + '.png';
    try { render(pos.local_file, typeof pos.gdo_x_pct === 'number' ? pos.gdo_x_pct : 5, stamps, out); imgs++; coded += stamps.length; }
    catch (e) { console.error('render fail', pos.label, 'p' + pos.page, '-', e.message); fails++; }
  }
  try { fs.unlinkSync(HTMLTMP); } catch (e) {}
  console.log('stamped ' + imgs + ' page-images (' + coded + ' codes), ' + fails + ' failures -> ' + OUTROOT);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
