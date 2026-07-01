// list_clients_for_folder.js <Window_NN> : build a simple PDF listing the matched clients for every
// stamped image in a Downloads/DERM_Stamped/<folder> directory, grouped by ticket/manifest.
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const { q } = require('./lib/db');
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

(async () => {
  const folder = process.argv[2];
  if (!folder) { console.error('usage: node list_clients_for_folder.js <Window_NN>'); process.exit(1); }
  const dir = path.join('C:/Users/FRED/Downloads/DERM_Stamped', folder);
  const files = fs.readdirSync(dir).filter(f => /^ticket_.*\.png$/.test(f)).sort();
  const wms = [...new Set(files.map(f => f.match(/^ticket_(\d+)_p(\d+)/)[1]))];
  if (!wms.length) { console.error('no ticket_*.png files found in', dir); process.exit(1); }

  const rows = await q(`
    select m.white_manifest_number, m.page, m.row_index, m.facility_name_read, m.address_read,
           m.assignment_status, c.client_code, c.name as client_name
    from derm.address_row_map m
    left join public.clients c on c.id = m.matched_client_id
    where m.white_manifest_number in (${wms.map(w => `'${w}'`).join(',')})
    order by m.white_manifest_number, m.page, m.row_index`);

  const byWm = new Map();
  for (const r of rows) {
    if (!byWm.has(r.white_manifest_number)) byWm.set(r.white_manifest_number, []);
    byWm.get(r.white_manifest_number).push(r);
  }

  const blocks = wms.map(wm => {
    const rs = byWm.get(wm) || [];
    const pages = [...new Set(rs.map(r => r.page))].sort((a, b) => a - b);
    const trs = rs.map(r => {
      const matched = r.assignment_status === 'matched' && r.client_code;
      const code = matched ? esc(r.client_code) : '<span class="q">unmatched</span>';
      const name = esc(r.client_name || r.facility_name_read || '');
      return `<tr class="${matched ? '' : 'flag'}"><td class="ri">${r.page}.${r.row_index}</td><td class="code">${code}</td><td>${name}</td><td class="addr">${esc(r.address_read || '')}</td></tr>`;
    }).join('');
    return `<div class="sheet"><div class="hd"><b>Ticket ${esc(wm)}</b> &middot; ${pages.length} page${pages.length > 1 ? 's' : ''}</div>
      <table><thead><tr><th>Row</th><th>Code</th><th>Client</th><th>Address</th></tr></thead><tbody>${trs}</tbody></table></div>`;
  }).join('');

  const totalRows = rows.length, matchedRows = rows.filter(r => r.assignment_status === 'matched' && r.client_code).length;
  const html = `<!doctype html><html><head><meta charset="utf-8"><style>
   body{font-family:'Segoe UI',system-ui,sans-serif;color:#2b2b2b;margin:0;font-size:12px}.doc{max-width:940px;margin:0 auto;padding:36px 46px}
   h1{font-size:20px;margin:0 0 2px}.sub{color:#777;margin:0 0 18px}
   .sheet{border:1px solid #eee;border-radius:6px;padding:8px 10px;margin:0 0 14px;page-break-inside:avoid}
   .hd{font-size:12px;color:#333;margin-bottom:6px}
   table{width:100%;border-collapse:collapse}th{font-size:9px;text-transform:uppercase;color:#999;text-align:left;border-bottom:1px solid #ddd;padding:3px 6px}
   td{padding:3px 6px;border-bottom:1px solid #f2f2f2;vertical-align:top}.ri{color:#aaa;width:34px}.code{font-family:Consolas,monospace;font-weight:700;width:80px}
   .addr{color:#555}tr.flag{background:#fff8e1}.q{color:#e67700;font-weight:700;font-style:italic}
   </style></head><body><div class="doc">
   <h1>DERM Client List — ${esc(folder)}</h1><p class="sub">${wms.length} ticket${wms.length > 1 ? 's' : ''} &middot; ${totalRows} facility rows &middot; ${matchedRows} matched to a client</p>
   ${blocks}
   </div></body></html>`;

  const chrome = ['C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe', 'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe', (process.env.LOCALAPPDATA || '') + '\\Google\\Chrome\\Application\\chrome.exe'].find(c => fs.existsSync(c));
  const htmlPath = path.resolve(__dirname, 'data', `_clientlist_${folder}.html`);
  fs.writeFileSync(htmlPath, html);
  const out = `C:/Users/FRED/Downloads/DERM_ClientList_${folder}.pdf`;
  execSync(`"${chrome}" --headless=new --disable-gpu --no-pdf-header-footer --print-to-pdf="${out}" "file:///${htmlPath.replace(/\\/g, '/')}"`, { stdio: 'pipe' });
  console.log(`${wms.length} tickets, ${totalRows} rows (${matchedRows} matched) -> ${out}`);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
