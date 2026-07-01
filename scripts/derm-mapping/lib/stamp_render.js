// Shared: render client codes onto a sheet image at %-positions, + row-alignment helpers.
const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const CHROME = ['C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe', 'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe', (process.env.LOCALAPPDATA || '') + '\\Google\\Chrome\\Application\\chrome.exe'].find(c => fs.existsSync(c));
const HTMLTMP = path.resolve(__dirname, '..', 'data', '_stamp_tmp.html');

const norm = s => String(s || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
const toks = s => new Set(norm(s).split(' ').filter(t => t.length > 2));
function overlap(a, b) { const A = toks(a), B = toks(b); let n = 0; for (const t of A) if (B.has(t)) n++; return n; }
function jpegSize(b) { let i = 2; while (i < b.length) { if (b[i] !== 0xFF) { i++; continue; } const m = b[i + 1]; if (m >= 0xC0 && m <= 0xCF && m !== 0xC4 && m !== 0xC8 && m !== 0xCC) return { w: b.readUInt16BE(i + 7), h: b.readUInt16BE(i + 5) }; i += 2 + b.readUInt16BE(i + 2); } return null; }
function pngSize(b) { return { w: b.readUInt32BE(16), h: b.readUInt32BE(20) }; }
function imgSize(buf) { return (buf[0] === 0x89 && buf[1] === 0x50) ? pngSize(buf) : jpegSize(buf); }

// Align DB confirmed rows (code+facility) to located position rows (facility_name+y_pct).
// Returns stamps [{code, y_pct}] (+ carries address if present). gdoX clamped to left column.
function buildStamps(dbrows, posRows) {
  const used = new Set(), stamps = [];
  for (const d of dbrows) {
    let best = null, bs = 0;
    for (const pr of (posRows || [])) { if (used.has(pr)) continue; const sc = overlap(d.facility_name_read || d.facility, pr.facility_name); if (sc > bs) { bs = sc; best = pr; } }
    if (!best || bs === 0) best = (posRows || []).find(pr => pr.row_index === d.row_index && !used.has(pr)) || null;
    if (best && typeof best.y_pct === 'number') { used.add(best); stamps.push({ code: d.code, y_pct: Math.max(2, Math.min(96, best.y_pct)), address: d.address_read || d.address || '' }); }
  }
  return stamps;
}

function render(imgPath, gdoXin, stamps, out) {
  if (!CHROME) throw new Error('Chrome not found');
  const buf = fs.readFileSync(imgPath);
  const sz = imgSize(buf);
  if (!sz) throw new Error('no dimensions for ' + imgPath);
  const { w, h } = sz, mime = (buf[0] === 0x89) ? 'image/png' : 'image/jpeg', b64 = buf.toString('base64');
  const gdoX = (typeof gdoXin === 'number' && gdoXin >= 0.5 && gdoXin <= 14) ? gdoXin : 6;
  const fsz = Math.round(w * 0.017);
  const labels = stamps.map(s => `<div class="code" style="left:${gdoX}%;top:${Math.max(2, Math.min(96, s.y_pct))}%">${String(s.code).replace(/[<>]/g, '')}</div>`).join('');
  const html = `<!doctype html><html><head><meta charset="utf-8"><style>
   *{margin:0;padding:0;box-sizing:border-box}.wrap{position:relative;width:${w}px}img{width:${w}px;display:block}
   .code{position:absolute;color:#d40000;font-weight:800;font-family:Consolas,'Courier New',monospace;font-size:${fsz}px;
     background:rgba(255,255,255,.5);padding:0 2px;transform:translate(-50%,-50%);white-space:nowrap;line-height:1;border-radius:2px}
   </style></head><body><div class="wrap"><img src="data:${mime};base64,${b64}">${labels}</div></body></html>`;
  fs.writeFileSync(HTMLTMP, html);
  cp.execSync(`"${CHROME}" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --screenshot="${out}" --window-size=${w},${h} "file:///${HTMLTMP.replace(/\\/g, '/')}"`, { stdio: 'pipe' });
}
module.exports = { render, buildStamps, imgSize, overlap, norm };
