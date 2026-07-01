// Build labeled contact-sheet PNGs of the top-right-corner crops for a list of images, so a human
// (or the orchestrating agent, reading directly rather than delegating) can visually re-verify every
// sheet's top-right number in a handful of composite reads instead of one read per image.
const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const CHROME = ['C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe', 'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe', (process.env.LOCALAPPDATA || '') + '\\Google\\Chrome\\Application\\chrome.exe'].find(c => fs.existsSync(c));
const D = path.resolve(__dirname, 'data');
const pending = JSON.parse(fs.readFileSync(path.join(D, '_pending_classify.json'), 'utf8'));

const BATCH = 20;
for (let b = 0; b * BATCH < pending.length; b++) {
  const items = pending.slice(b * BATCH, (b + 1) * BATCH);
  const rows = items.map(im => {
    const cropPath = path.join(D, 'crops', 'tr2_' + im.key + '.png').replace(/\\/g, '/');
    return `<div class="row"><div class="label">${im.key} (wm ${im.wm})</div><img src="file:///${cropPath}"></div>`;
  }).join('\n');
  const html = `<!doctype html><html><head><style>
    body{margin:0;font-family:Consolas,monospace;background:#fff}
    .row{display:flex;align-items:center;border-bottom:1px solid #ccc}
    .label{width:220px;padding:4px;font-size:14px;font-weight:bold;flex-shrink:0}
    img{height:60px}
  </style></head><body>${rows}</body></html>`;
  const htmlPath = path.join(D, '_contact_' + b + '.html');
  fs.writeFileSync(htmlPath, html);
  const outPath = path.join(D, 'crops', 'contact_sheet_' + b + '.png');
  cp.execSync(`"${CHROME}" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --screenshot="${outPath}" --window-size=900,${items.length * 65 + 20} "file:///${htmlPath.replace(/\\/g, '/')}"`, { stdio: 'pipe' });
  console.log('wrote', outPath, 'with', items.length, 'rows');
}
