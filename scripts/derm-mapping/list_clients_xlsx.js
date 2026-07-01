// list_clients_xlsx.js <Window_NN> : build a filterable .xlsx (saved inside the Downloads/DERM_Stamped/
// <folder> directory, next to the images) listing every facility row for that folder's tickets, with a
// hyperlink per row straight to its stamped image -- so Yannick can filter to Unmatched and click
// through to add the missing client code on the image.
const fs = require('fs');
const path = require('path');
const XLSX = require('xlsx');
const { q } = require('./lib/db');

(async () => {
  const folder = process.argv[2];
  if (!folder) { console.error('usage: node list_clients_xlsx.js <Window_NN>'); process.exit(1); }
  const dir = path.join('C:/Users/FRED/Downloads/DERM_Stamped', folder);
  const files = fs.readdirSync(dir).filter(f => /^ticket_.*\.png$/.test(f)).sort();
  if (!files.length) { console.error('no ticket_*.png files found in', dir); process.exit(1); }
  // map wm+page -> image filename
  const imageFor = {};
  for (const f of files) {
    const m = f.match(/^ticket_(\d+)_p(\d+)_/);
    if (m) imageFor[`${m[1]}_${m[2]}`] = f;
  }
  const wms = [...new Set(files.map(f => f.match(/^ticket_(\d+)_p(\d+)/)[1]))];

  const rows = await q(`
    select m.white_manifest_number, m.page, m.row_index, m.facility_name_read, m.address_read,
           m.assignment_status, c.client_code, c.name as client_name
    from derm.address_row_map m
    left join public.clients c on c.id = m.matched_client_id
    where m.white_manifest_number in (${wms.map(w => `'${w}'`).join(',')})
    order by (m.assignment_status = 'matched' and c.client_code is not null) asc, m.white_manifest_number, m.page, m.row_index`);

  const header = ['Status', 'Ticket', 'Row', 'Code', 'Client', 'Address (read)', 'Image'];
  const aoa = [header];
  const hyperlinks = []; // {r, c, target}
  rows.forEach((r, i) => {
    const matched = r.assignment_status === 'matched' && r.client_code;
    const img = imageFor[`${r.white_manifest_number}_${r.page}`] || '';
    const rIdx = aoa.length; // row index in aoa (0-based, header is row 0)
    aoa.push([
      matched ? 'matched' : 'UNMATCHED',
      r.white_manifest_number,
      `${r.page}.${r.row_index}`,
      r.client_code || '',
      r.client_name || r.facility_name_read || '',
      r.address_read || '',
      img,
    ]);
    if (img) hyperlinks.push({ row: rIdx, col: 6, target: img });
  });

  const ws = XLSX.utils.aoa_to_sheet(aoa);
  ws['!cols'] = [{ wch: 10 }, { wch: 10 }, { wch: 7 }, { wch: 12 }, { wch: 30 }, { wch: 40 }, { wch: 34 }];
  ws['!autofilter'] = { ref: `A1:G${aoa.length}` };
  for (const h of hyperlinks) {
    const addr = XLSX.utils.encode_cell({ r: h.row, c: h.col });
    ws[addr].l = { Target: h.target, Tooltip: 'Open image' };
  }
  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, ws, 'Clients');
  const out = path.join(dir, `ClientList_${folder}.xlsx`);
  XLSX.writeFile(wb, out);
  const unmatched = rows.filter(r => !(r.assignment_status === 'matched' && r.client_code)).length;
  console.log(`${rows.length} rows (${unmatched} unmatched) -> ${out}`);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
