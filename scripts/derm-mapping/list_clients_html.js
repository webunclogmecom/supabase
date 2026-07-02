// list_clients_html.js <Window_NN> : build a self-contained HTML client list, saved into
// Downloads/DERM_Stamped/<folder> next to the stamped images. Unlike the PDF version, links here are
// genuinely relative (bare filename) -- a real .html file preserves that at open-time, so it resolves
// correctly wherever the whole folder ends up (a different machine, a different drive, a zip extracted
// somewhere else), as long as the html and the images stay together. Includes a search box + status
// filter (All / Missing / Matched) via plain JS, no external dependencies -- works fully offline.
const fs = require('fs');
const path = require('path');
const { q } = require('./lib/db');
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

(async () => {
  const folder = process.argv[2];
  if (!folder) { console.error('usage: node list_clients_html.js <Window_NN>'); process.exit(1); }
  const dir = path.join('C:/Users/FRED/Downloads/DERM_Stamped', folder);
  const files = fs.readdirSync(dir).filter(f => /^ticket_.*\.png$/.test(f)).sort();
  const wms = [...new Set(files.map(f => f.match(/^ticket_(\d+)_p(\d+)/)[1]))];
  if (!wms.length) { console.error('no ticket_*.png files found in', dir); process.exit(1); }
  const imageFor = {};
  for (const f of files) { const m = f.match(/^ticket_(\d+)_p(\d+)_/); if (m) imageFor[`${m[1]}_${m[2]}`] = f; }

  const rows = await q(`
    select m.white_manifest_number, m.page, m.row_index, m.facility_name_read, m.address_read,
           m.assignment_status, c.client_code, c.name as client_name
    from derm.address_row_map m
    left join public.clients c on c.id = m.matched_client_id
    where m.white_manifest_number in (${wms.map(w => `'${w}'`).join(',')})
    order by m.white_manifest_number, m.page, m.row_index`);

  const trs = rows.map(r => {
    const matched = r.assignment_status === 'matched' && r.client_code;
    const file = imageFor[`${r.white_manifest_number}_${r.page}`];
    const code = matched ? esc(r.client_code) : '<span class="q">unmatched</span>';
    const name = esc(r.client_name || r.facility_name_read || '');
    const link = file ? `<a href="${esc(file)}" target="_blank">${esc(file)}</a>` : '';
    const searchText = esc([r.white_manifest_number, r.client_code, name, r.address_read, file].filter(Boolean).join(' ').toLowerCase());
    return `<tr class="${matched ? 'matched' : 'missing'}" data-search="${searchText}">
      <td class="ri">${r.page}.${r.row_index}</td><td>${esc(r.white_manifest_number)}</td>
      <td class="code">${code}</td><td>${name}</td><td class="addr">${esc(r.address_read || '')}</td>
      <td class="file">${link}</td></tr>`;
  }).join('');

  const totalRows = rows.length, missingCount = rows.filter(r => !(r.assignment_status === 'matched' && r.client_code)).length;
  const html = `<!doctype html><html><head><meta charset="utf-8"><title>DERM Client List — ${esc(folder)}</title><style>
   body{font-family:'Segoe UI',system-ui,sans-serif;color:#2b2b2b;margin:0;font-size:13px;background:#fafafa}
   .doc{max-width:1000px;margin:0 auto;padding:28px 32px}
   h1{font-size:20px;margin:0 0 2px}.sub{color:#777;margin:0 0 14px}
   .toolbar{display:flex;gap:10px;align-items:center;margin:0 0 14px;position:sticky;top:0;background:#fafafa;padding:8px 0;z-index:1}
   #search{flex:1;padding:7px 10px;font-size:13px;border:1px solid #ccc;border-radius:5px}
   .filterbtn{padding:6px 12px;font-size:12px;border:1px solid #ccc;border-radius:5px;background:#fff;cursor:pointer}
   .filterbtn.active{background:#1c5779;color:#fff;border-color:#1c5779}
   table{width:100%;border-collapse:collapse;background:#fff;border-radius:6px;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,.08)}
   th{font-size:10px;text-transform:uppercase;color:#999;text-align:left;border-bottom:1px solid #ddd;padding:6px 8px;background:#f5f5f5}
   td{padding:6px 8px;border-bottom:1px solid #f2f2f2;vertical-align:top}
   .ri{color:#aaa;width:40px}.code{font-family:Consolas,monospace;font-weight:700;width:90px}
   .addr{color:#555}.file{font-family:Consolas,monospace;font-size:11px;color:#444;width:220px}
   tr.missing{background:#fff8e1}.q{color:#e67700;font-weight:700;font-style:italic}
   a{color:#1c5779;font-weight:600;text-decoration:none}a:hover{text-decoration:underline}
   .count{color:#777;font-size:12px;margin-left:auto}
   .note{background:#eef6fa;border:1px solid #cfe4ee;border-radius:6px;padding:8px 10px;margin:0 0 14px;font-size:11px;color:#444}
   </style></head><body><div class="doc">
   <h1>DERM Client List — ${esc(folder)}</h1>
   <p class="sub">${wms.length} tickets &middot; ${totalRows} facility rows &middot; ${missingCount} missing</p>
   <div class="note">Keep this file in the same folder as the images. Click a filename to open that sheet.</div>
   <div class="toolbar">
     <input id="search" type="text" placeholder="Search ticket, code, client, address, filename...">
     <button class="filterbtn active" data-filter="all">All</button>
     <button class="filterbtn" data-filter="missing">Missing (${missingCount})</button>
     <button class="filterbtn" data-filter="matched">Matched</button>
     <span class="count" id="count"></span>
   </div>
   <table><thead><tr><th>Row</th><th>Ticket</th><th>Code</th><th>Client</th><th>Address</th><th>Image file</th></tr></thead>
   <tbody id="tbody">${trs}</tbody></table>
   </div>
   <script>
   const rows = [...document.querySelectorAll('#tbody tr')];
   const searchEl = document.getElementById('search');
   const countEl = document.getElementById('count');
   let statusFilter = 'all';
   function apply() {
     const q = searchEl.value.trim().toLowerCase();
     let shown = 0;
     for (const tr of rows) {
       const statusOk = statusFilter === 'all' || tr.classList.contains(statusFilter);
       const searchOk = !q || tr.dataset.search.includes(q);
       const visible = statusOk && searchOk;
       tr.style.display = visible ? '' : 'none';
       if (visible) shown++;
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

  const out = path.join(dir, `ClientList_${folder}.html`);
  fs.writeFileSync(out, html);
  console.log(`${wms.length} tickets, ${totalRows} rows (${missingCount} missing) -> ${out}`);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
