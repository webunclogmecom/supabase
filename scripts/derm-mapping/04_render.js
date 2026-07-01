// 04_render.js <windowNumber> : build a legend bundle PDF for one 2-week window from
// derm.address_row_map. Splits sheets into UNCONFIRMED (any row not high-confidence matched)
// and CONFIRMED. Unconfirmed rows show the code blank + "?". Output to C:/Users/FRED/Downloads/.
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const { q } = require('./lib/db');
const WINDOWS = require('./lib/windows');
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function sheetHtml(title, sheets) {
  if (!sheets.length) return `<h2>${title}</h2><p class="muted">none</p>`;
  const blocks = sheets.map(s => {
    const rows = s.rows.map(r => {
      const conf = r.assignment_status === 'matched' && r.confidence === 'high';
      const code = conf ? esc(r.code || '') : '<span class="q">?</span>';
      return `<tr class="${conf ? '' : 'flag'}"><td class="ri">${r.page}.${r.row_index}</td><td class="code">${code}</td><td>${esc(r.facility_name_read || '')}</td><td class="addr">${esc(r.address_read || '')}</td></tr>`;
    }).join('');
    const links = s.page_urls.map((u, i) => `<a href="${esc(u)}">Image ${i + 1}</a>`).join(' &middot; ');
    return `<div class="sheet"><div class="hd"><b>${esc(s.dump_date)}</b> &middot; ticket ${esc(s.wm || '—')} &middot; ${links}</div>
      <table><thead><tr><th>Row</th><th>Code</th><th>Facility (read)</th><th>Address (read)</th></tr></thead><tbody>${rows}</tbody></table></div>`;
  }).join('');
  return `<h2>${title} <span class="muted">(${sheets.length})</span></h2>${blocks}`;
}

(async () => {
  const n = parseInt(process.argv[2], 10);
  const w = WINDOWS.find(x => x.n === n);
  if (!w) { console.error('usage: node 04_render.js <1..13>'); process.exit(1); }
  const rows = await q(`
    SELECT m.dump_folder, m.white_manifest_number AS wm, m.page, m.row_index, m.image_url,
           m.facility_name_read, m.address_read, m.assignment_status, m.confidence,
           c.client_code AS code,
           (SELECT coalesce(dm.dump_ticket_date,dm.service_date)::text FROM derm_manifests dm
             WHERE dm.white_manifest_number=m.white_manifest_number ORDER BY 1 LIMIT 1) AS dump_date
    FROM derm.address_row_map m LEFT JOIN clients c ON c.id=m.matched_client_id
    WHERE m.white_manifest_number IN (
       SELECT white_manifest_number FROM derm_manifests
        WHERE deleted_at IS NULL AND coalesce(dump_ticket_date,service_date) >= '${w.from}'
          AND coalesce(dump_ticket_date,service_date) <= '${w.to}')
    ORDER BY dump_date DESC, m.dump_folder, m.page, m.row_index`);
  const byFolder = new Map();
  for (const r of rows) {
    if (!byFolder.has(r.dump_folder)) byFolder.set(r.dump_folder, { dump_folder: r.dump_folder, wm: r.wm, dump_date: r.dump_date, page_urls: [], rows: [] });
    const s = byFolder.get(r.dump_folder);
    s.rows.push(r);
  }
  // reconstruct page_urls per folder (distinct image_url in page order)
  for (const s of byFolder.values()) { const seen = new Set(); for (const r of s.rows) if (r.image_url && !seen.has(r.image_url)) { seen.add(r.image_url); s.page_urls.push(r.image_url); } }
  const all = [...byFolder.values()];
  const isConfirmed = s => s.rows.every(r => r.assignment_status === 'matched' && r.confidence === 'high');
  const unconfirmed = all.filter(s => !isConfirmed(s));
  const confirmed = all.filter(isConfirmed);
  const html = `<!doctype html><html><head><meta charset="utf-8"><style>
   body{font-family:'Segoe UI',system-ui,sans-serif;color:#2b2b2b;margin:0;font-size:12px}.doc{max-width:940px;margin:0 auto;padding:36px 46px}
   h1{font-size:22px;margin:0 0 2px}.sub{color:#777;margin:0 0 16px}.muted{color:#999;font-weight:400}
   h2{font-size:15px;margin:20px 0 8px;border-bottom:2px solid #eee;padding-bottom:4px}
   .sheet{border:1px solid #eee;border-radius:6px;padding:8px 10px;margin:0 0 12px;page-break-inside:avoid}
   .hd{font-size:11px;color:#555;margin-bottom:5px}.hd a{color:#1c5779}
   table{width:100%;border-collapse:collapse}th{font-size:9px;text-transform:uppercase;color:#999;text-align:left;border-bottom:1px solid #ddd;padding:3px 6px}
   td{padding:3px 6px;border-bottom:1px solid #f2f2f2;vertical-align:top}.ri{color:#aaa;width:34px}.code{font-family:Consolas,monospace;font-weight:700;width:70px}
   .addr{color:#555}tr.flag{background:#fff8e1}.q{color:#e67700;font-weight:700}
   </style></head><body><div class="doc">
   <h1>DERM Addresses — Window ${n} of 13</h1><p class="sub">dump dates ${w.from} to ${w.to} &middot; ${unconfirmed.length} to confirm &middot; ${confirmed.length} confirmed</p>
   <div class="sheet" style="background:#f7f6f3"><b>Yannick:</b> the <b>Unconfirmed</b> sheets below have blank codes marked <span class="q">?</span> — please fill those first. The <b>Confirmed</b> sheets are for reference; correct anything that looks off.</div>
   ${sheetHtml('Unconfirmed — tackle first', unconfirmed)}
   ${sheetHtml('Confirmed', confirmed)}
   </div></body></html>`;
  const chrome = ['C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe', 'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe', (process.env.LOCALAPPDATA || '') + '\\Google\\Chrome\\Application\\chrome.exe'].find(c => fs.existsSync(c));
  const htmlPath = path.resolve(__dirname, 'data', `render_${String(n).padStart(2, '0')}.html`);
  fs.writeFileSync(htmlPath, html);
  const out = `C:/Users/FRED/Downloads/DERM_RowMap_Window_${String(n).padStart(2, '0')}_${w.from}_to_${w.to}.pdf`;
  execSync(`"${chrome}" --headless=new --disable-gpu --no-pdf-header-footer --print-to-pdf="${out}" "file:///${htmlPath.replace(/\\/g, '/')}"`, { stdio: 'pipe' });
  console.log(`window ${n}: ${unconfirmed.length} unconfirmed, ${confirmed.length} confirmed -> ${out}`);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
