// 01_prep.js <windowNumber> : for one 2-week window, pull each dump-ticket sheet's candidate
// clients (code/name/DB address) + deduped image pages, download the images locally, and write
// data/sheets_<nn>.json. Groups by dump ticket (white_manifest_number; falls back to image URL).
const https = require('https');
const fs = require('fs');
const path = require('path');
const { q } = require('./lib/db');
const WINDOWS = require('./lib/windows');

const DATA = path.resolve(__dirname, 'data');
const fileName = u => { try { return decodeURIComponent(String(u).split('/').pop().split('?')[0] || u).toLowerCase(); } catch (e) { return String(u).toLowerCase(); } };
const ext = u => { const e = fileName(u).match(/\.(jpe?g|png|pdf|webp|heic)$/i); return e ? e[0].toLowerCase() : '.jpg'; };
function dl(url, dest) {
  return new Promise((res, rej) => {
    const go = (u, n) => { if (n > 5) return rej(new Error('redirects')); https.get(u, r => {
      if (r.statusCode >= 300 && r.statusCode < 400 && r.headers.location) { r.resume(); return go(r.headers.location, n + 1); }
      if (r.statusCode !== 200) { r.resume(); return rej(new Error('HTTP ' + r.statusCode)); }
      const f = fs.createWriteStream(dest); r.pipe(f); f.on('finish', () => f.close(() => res(dest))); }).on('error', rej); };
    go(url, 0);
  });
}
(async () => {
  const n = parseInt(process.argv[2], 10);
  const w = WINDOWS.find(x => x.n === n);
  if (!w) { console.error('usage: node 01_prep.js <1..13>'); process.exit(1); }
  const imgDir = path.join(DATA, 'images', 'w' + String(n).padStart(2, '0'));
  fs.mkdirSync(imgDir, { recursive: true });
  const rows = await q(`
    SELECT coalesce(m.dump_ticket_date, m.service_date)::text AS dump_date,
           m.white_manifest_number AS wm, m.derm_address_url AS url, m.derm_address_extra_urls AS extras,
           c.id AS client_id, c.client_code, c.name,
           (SELECT concat_ws(', ', nullif(p.address,''), nullif(p.city,''), nullif(p.state,''), nullif(p.zip,''))
              FROM properties p WHERE p.client_id=c.id ORDER BY p.is_primary DESC NULLS LAST, p.id LIMIT 1) AS address
    FROM derm_manifests m JOIN clients c ON c.id=m.client_id
    WHERE m.deleted_at IS NULL AND m.derm_address_url IS NOT NULL
      AND coalesce(m.dump_ticket_date,m.service_date) >= '${w.from}'
      AND coalesce(m.dump_ticket_date,m.service_date) <= '${w.to}'
    ORDER BY dump_date DESC, m.white_manifest_number`);
  const sheets = new Map(); // key -> sheet
  for (const r of rows) {
    const key = r.wm ? 'WM:' + r.wm : 'URL:' + r.url;
    if (!sheets.has(key)) sheets.set(key, { dump_date: r.dump_date, wm: r.wm, dump_folder: null, candidates: [], imgs: new Map() });
    const s = sheets.get(key);
    s.candidates.push({ code: r.client_code || ('NOCODE-' + r.client_id), name: r.name, address: r.address });
    const urls = [r.url, ...(Array.isArray(r.extras) ? r.extras : [])];
    for (const u of urls) if (u && !s.imgs.has(fileName(u))) s.imgs.set(fileName(u), u);
  }
  const out = [];
  let si = 0;
  for (const s of sheets.values()) {
    si++;
    const pages = [...s.imgs.values()];
    // dump_folder = the storage folder that identifies this physical sheet-set (e.g. 'derm/1218')
    const m = String(pages[0] || '').match(/\/manifests\/([^?]+)\/[^/?]+$/);
    s.dump_folder = m ? m[1] : ('window' + n + '-sheet' + si);
    const local = [];
    for (let i = 0; i < pages.length; i++) {
      const dest = path.join(imgDir, `s${String(si).padStart(2, '0')}_p${i + 1}${ext(pages[i])}`);
      try { await dl(pages[i], dest); local.push(dest.replace(/\\/g, '/')); } catch (e) { local.push('DL_FAIL:' + e.message); }
    }
    out.push({ label: `w${n}-s${si}`, dump_folder: s.dump_folder, wm: s.wm, dump_date: s.dump_date,
      candidates: s.candidates, page_urls: pages, local_files: local });
  }
  fs.writeFileSync(path.join(DATA, `sheets_${String(n).padStart(2, '0')}.json`), JSON.stringify({ window: w, sheets: out }, null, 2));
  console.log(`window ${n} (${w.from}..${w.to}): ${out.length} sheets, ${out.reduce((a, s) => a + s.page_urls.length, 0)} pages`);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
