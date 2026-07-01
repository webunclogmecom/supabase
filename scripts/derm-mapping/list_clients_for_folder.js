// list_clients_for_folder.js <Window_NN> : build a PDF listing the matched clients for every stamped
// image in a Downloads/DERM_Stamped/<folder> directory, saved into that same folder. Missing-code rows
// are pulled into their own section up top. Each row shows its image filename as plain text -- that's
// the portable part, readable regardless of viewer or whose machine opens the PDF. The filename is
// ALSO a link, but note: Chrome's print-to-pdf always bakes an absolute file:// URI into the PDF (it
// does not preserve true relative links, even from a relative href -- confirmed by inspecting the
// output), so the click-to-open only works on THIS machine, in this exact folder. On any other machine
// (e.g. Yannick's) the link target won't exist -- he has to use the plain filename text instead.
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
  const imageFor = {};
  for (const f of files) { const m = f.match(/^ticket_(\d+)_p(\d+)_/); if (m) imageFor[`${m[1]}_${m[2]}`] = f; }

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

  const rowTr = r => {
    const matched = r.assignment_status === 'matched' && r.client_code;
    const code = matched ? esc(r.client_code) : '<span class="q">unmatched</span>';
    const name = esc(r.client_name || r.facility_name_read || '');
    const file = imageFor[`${r.white_manifest_number}_${r.page}`];
    const imgCell = file ? `<a href="${esc(file)}">${esc(file)}</a>` : '';
    return `<tr class="${matched ? '' : 'flag'}"><td class="ri">${r.page}.${r.row_index}</td><td>${esc(r.white_manifest_number)}</td><td class="code">${code}</td><td>${name}</td><td class="addr">${esc(r.address_read || '')}</td><td class="file">${imgCell}</td></tr>`;
  };
  const THEAD = '<thead><tr><th>Row</th><th>Ticket</th><th>Code</th><th>Client</th><th>Address</th><th>Image file</th></tr></thead>';

  const missing = rows.filter(r => !(r.assignment_status === 'matched' && r.client_code));
  const missingHtml = missing.length
    ? `<h2>Missing codes (${missing.length})</h2>
       <table>${THEAD}<tbody>${missing.map(rowTr).join('')}</tbody></table>`
    : '';

  const blocks = wms.map(wm => {
    const rs = byWm.get(wm) || [];
    const pages = [...new Set(rs.map(r => r.page))].sort((a, b) => a - b);
    const trs = rs.map(rowTr).join('');
    return `<div class="sheet"><div class="hd"><b>Ticket ${esc(wm)}</b> &middot; ${pages.length} page${pages.length > 1 ? 's' : ''}</div>
      <table>${THEAD}<tbody>${trs}</tbody></table></div>`;
  }).join('');

  const totalRows = rows.length, matchedRows = totalRows - missing.length;
  const baseHref = `file:///${dir.replace(/\\/g, '/')}/`;
  const html = `<!doctype html><html><head><meta charset="utf-8"><base href="${esc(baseHref)}"><style>
   body{font-family:'Segoe UI',system-ui,sans-serif;color:#2b2b2b;margin:0;font-size:12px}.doc{max-width:940px;margin:0 auto;padding:36px 46px}
   h1{font-size:20px;margin:0 0 2px}.sub{color:#777;margin:0 0 18px}
   h2{font-size:14px;margin:0 0 8px;border-bottom:2px solid #eee;padding-bottom:4px}
   .sheet{border:1px solid #eee;border-radius:6px;padding:8px 10px;margin:0 0 14px;page-break-inside:avoid}
   .hd{font-size:12px;color:#333;margin-bottom:6px}
   table{width:100%;border-collapse:collapse;margin-bottom:20px}th{font-size:9px;text-transform:uppercase;color:#999;text-align:left;border-bottom:1px solid #ddd;padding:3px 6px}
   td{padding:3px 6px;border-bottom:1px solid #f2f2f2;vertical-align:top}.ri{color:#aaa;width:34px}.code{font-family:Consolas,monospace;font-weight:700;width:80px}
   td a{color:#1c5779;font-weight:600;text-decoration:none}td a:hover{text-decoration:underline}
   .addr{color:#555}tr.flag{background:#fff8e1}.q{color:#e67700;font-weight:700;font-style:italic}
   .sheet table{margin-bottom:0}.file{font-family:Consolas,monospace;font-size:10px;color:#444;width:170px}
   .note{background:#f7f6f3;border:1px solid #eee;border-radius:6px;padding:8px 10px;margin:0 0 16px;font-size:11px;color:#555}
   </style></head><body><div class="doc">
   <h1>DERM Client List — ${esc(folder)}</h1><p class="sub">${wms.length} ticket${wms.length > 1 ? 's' : ''} &middot; ${totalRows} facility rows &middot; ${matchedRows} matched &middot; ${missing.length} missing</p>
   <div class="note">The <b>Image file</b> column names the exact file for each row. The link only opens the image on the machine this PDF was generated on -- if you're viewing this on a different computer, use the filename to find it in the matching Window folder instead.</div>
   ${missingHtml}
   <h2>All tickets</h2>
   ${blocks}
   </div></body></html>`;

  const chrome = ['C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe', 'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe', (process.env.LOCALAPPDATA || '') + '\\Google\\Chrome\\Application\\chrome.exe'].find(c => fs.existsSync(c));
  const htmlPath = path.resolve(__dirname, 'data', `_clientlist_${folder}.html`);
  fs.writeFileSync(htmlPath, html);
  const out = path.join(dir, `ClientList_${folder}.pdf`);
  execSync(`"${chrome}" --headless=new --disable-gpu --no-pdf-header-footer --print-to-pdf="${out}" "file:///${htmlPath.replace(/\\/g, '/')}"`, { stdio: 'pipe' });
  console.log(`${wms.length} tickets, ${totalRows} rows (${missing.length} missing) -> ${out}`);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
