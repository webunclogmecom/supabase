// generate_master_index.js : build Downloads/DERM_Stamped/index.html — a MASTER searchable client
// list across ALL 13 windows (every row: code, client, address, window, ticket, link to the stamped
// image and to the per-window list). Same offline search/filter pattern as the per-window pages;
// all links relative so the whole DERM_Stamped folder stays portable.
const fs = require('fs');
const path = require('path');
const { q } = require('./lib/db');
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const ROOT = 'C:/Users/FRED/Downloads/DERM_Stamped';

(async () => {
  // map every stamped image across all windows: keys wm_page and dumpfolder_page -> Window_NN/file
  const imageFor = {}; const windowFor = {};
  const wms = new Set(); const dfs = new Set();
  for (const w of fs.readdirSync(ROOT).filter(d => /^Window_\d+$/.test(d)).sort()) {
    for (const f of fs.readdirSync(path.join(ROOT, w))) {
      let m = f.match(/^ticket_(\d+)_p(\d+)_/);
      if (m) { imageFor[`${m[1]}_${m[2]}`] = `${w}/${f}`; windowFor[m[1]] = w; wms.add(m[1]); continue; }
      m = f.match(/^window(\d+)_sheet(\d+)_p(\d+)_/);
      if (m) { const df = `window${m[1]}-sheet${m[2]}`; imageFor[`${df}_${m[3]}`] = `${w}/${f}`; windowFor[df] = w; dfs.add(df); }
    }
  }

  const conds = [];
  if (wms.size) conds.push(`m.white_manifest_number in (${[...wms].map(w => `'${w}'`).join(',')})`);
  if (dfs.size) conds.push(`m.dump_folder in (${[...dfs].map(d => `'${d}'`).join(',')})`);
  const rows = await q(`
    select m.white_manifest_number, m.dump_folder, m.page, m.row_index, m.facility_name_read, m.address_read,
           m.assignment_status, c.client_code, c.name as client_name
    from derm.address_row_map m
    left join public.clients c on c.id = m.matched_client_id
    where ${conds.join(' or ')}
    order by m.white_manifest_number nulls last, m.dump_folder, m.page, m.row_index`);

  const trs = rows.map(r => {
    const matched = r.assignment_status === 'matched' && r.client_code;
    const img = imageFor[`${r.white_manifest_number}_${r.page}`] || imageFor[`${r.dump_folder}_${r.page}`];
    const win = windowFor[r.white_manifest_number] || windowFor[r.dump_folder] || '';
    const code = matched ? esc(r.client_code) : '<span class="q">unmatched</span>';
    const name = esc(r.client_name || r.facility_name_read || '');
    const ticket = r.white_manifest_number ? esc(r.white_manifest_number) : '<span class="q">no ticket</span>';
    const winLink = win ? `<a href="${esc(win)}/ClientList_${esc(win)}.html">${esc(win.replace('_', ' '))}</a>` : '';
    const imgLink = img ? `<a href="${esc(img)}" target="_blank">${esc(img.split('/')[1])}</a>` : '';
    const searchText = esc([r.client_code, r.client_name, r.facility_name_read, r.address_read, r.white_manifest_number, win, img].filter(Boolean).join(' ').toLowerCase());
    return `<tr class="${matched ? 'matched' : 'missing'}" data-search="${searchText}">
      <td class="code">${code}</td><td>${name}</td><td class="addr">${esc(r.address_read || '')}</td>
      <td>${winLink}</td><td>${ticket}</td><td class="ri">${r.page}.${r.row_index}</td><td class="file">${imgLink}</td></tr>`;
  }).join('');

  const total = rows.length, missing = rows.filter(r => !(r.assignment_status === 'matched' && r.client_code)).length;
  const nSheets = wms.size + dfs.size;
  const today = new Date().toISOString().slice(0, 10);
  const html = `<!doctype html><html><head><meta charset="utf-8"><title>DERM Client Lists — All Windows</title><style>
 body{font-family:'Segoe UI',system-ui,sans-serif;color:#2b2b2b;margin:0;font-size:13px;background:#fafafa}
 .doc{max-width:1100px;margin:0 auto;padding:28px 32px}
 h1{font-size:20px;margin:0 0 2px}.sub{color:#777;margin:0 0 14px}
 .toolbar{display:flex;gap:10px;align-items:center;margin:0 0 14px;position:sticky;top:0;background:#fafafa;padding:8px 0;z-index:1}
 #search{flex:1;padding:7px 10px;font-size:13px;border:1px solid #ccc;border-radius:5px}
 .filterbtn{padding:6px 12px;font-size:12px;border:1px solid #ccc;border-radius:5px;background:#fff;cursor:pointer}
 .filterbtn.active{background:#1c5779;color:#fff;border-color:#1c5779}
 table{width:100%;border-collapse:collapse;background:#fff;border-radius:6px;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,.08)}
 th{font-size:10px;text-transform:uppercase;color:#999;text-align:left;border-bottom:1px solid #ddd;padding:6px 8px;background:#f5f5f5}
 td{padding:6px 8px;border-bottom:1px solid #f2f2f2;vertical-align:top}
 .ri{color:#aaa;width:40px}.code{font-family:Consolas,monospace;font-weight:700;width:90px}
 .addr{color:#555}.file{font-family:Consolas,monospace;font-size:11px;width:210px}
 tr.missing{background:#fff8e1}.q{color:#e67700;font-weight:700;font-style:italic}
 a{color:#1c5779;font-weight:600;text-decoration:none}a:hover{text-decoration:underline}
 .count{color:#777;font-size:12px;margin-left:auto}
 .note{background:#eef6fa;border:1px solid #cfe4ee;border-radius:6px;padding:8px 10px;margin:0 0 14px;font-size:11px;color:#444}
 </style></head><body><div class="doc">
 <h1>DERM Client List — All Windows (01–13)</h1>
 <p class="sub">Generated ${today} &middot; ${nSheets} tickets &middot; ${total} facility rows &middot; ${missing} missing codes</p>
 <div class="note">Master list across all 13 windows. Search any client code/name/address; click an image to open the stamped sheet, or the window to open that window's own list. Keep this file inside the <b>DERM_Stamped</b> folder.</div>
 <div class="toolbar">
   <input id="search" type="text" placeholder="Search code, client, address, ticket, window...">
   <button class="filterbtn active" data-filter="all">All</button>
   <button class="filterbtn" data-filter="missing">Missing (${missing})</button>
   <button class="filterbtn" data-filter="matched">Matched</button>
   <span class="count" id="count"></span>
 </div>
 <table><thead><tr><th>Code</th><th>Client</th><th>Address</th><th>Window</th><th>Ticket</th><th>Row</th><th>Image file</th></tr></thead>
 <tbody id="tbody">${trs}</tbody></table>
 </div>
 <script>
 const rows = [...document.querySelectorAll('#tbody tr')];
 const searchEl = document.getElementById('search');
 const countEl = document.getElementById('count');
 let statusFilter = 'all';
 function apply() {
   const qq = searchEl.value.trim().toLowerCase();
   let shown = 0;
   for (const tr of rows) {
     const ok = (statusFilter === 'all' || tr.classList.contains(statusFilter)) && (!qq || tr.dataset.search.includes(qq));
     tr.style.display = ok ? '' : 'none';
     if (ok) shown++;
   }
   countEl.textContent = shown + ' / ' + rows.length + ' rows';
 }
 searchEl.addEventListener('input', apply);
 document.querySelectorAll('.filterbtn').forEach(btn => btn.addEventListener('click', () => {
   document.querySelectorAll('.filterbtn').forEach(b => b.classList.remove('active'));
   btn.classList.add('active');
   statusFilter = btn.dataset.filter;
   apply();
 }));
 apply();
 </script>
 </body></html>`;

  const out = path.join(ROOT, 'index.html');
  fs.writeFileSync(out, html);
  console.log(`${nSheets} tickets, ${total} rows (${missing} missing) -> ${out}`);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
