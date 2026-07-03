// build_rematch_payload.js : payload for the FULL-ROSTER re-match of unmatched/low-confidence rows.
// The original engine only offered candidates whose visits fell in the sheet's 2-week window, so
// facilities of well-known clients ended 'unmatched' when their visit wasn't in that window (Fred's
// 827989-p2 example: "Bagel Boss / 9543 Harding" = 087-BB). This groups every unmatched/low row by
// sheet (with the RAW image path so agents OCR the actual handwriting) and embeds the full coded-client
// roster with property addresses.
const fs = require('fs');
const path = require('path');
const { q } = require('./lib/db');

(async () => {
  const state = JSON.parse(fs.readFileSync(path.resolve(__dirname, 'data', 'stamp_state_v3.json'), 'utf8'));
  const byWmPage = {}; const byDfPage = {};
  for (const e of state) {
    const m = e.key.match(/^w(\d+)-s(\d+)-p(\d+)$/);
    const df = m ? `window${m[1]}-sheet${m[2]}` : null;
    if (e.wm) byWmPage[`${e.wm}_${e.page || m[3]}`] = e;
    if (df) byDfPage[`${df}_${e.page || m[3]}`] = e;
  }

  const rows = await q(`
    select m.id, m.white_manifest_number wm, m.dump_folder df, m.page, m.row_index,
           m.facility_name_read, m.address_read, m.assignment_status, m.confidence
    from derm.address_row_map m
    where m.assignment_status in ('unmatched','low_confidence')
       or (m.assignment_status='matched' and m.confidence <> 'high')
    order by m.dump_folder, m.page, m.row_index`);

  const roster = await q(`
    select c.client_code code, c.name, c.status,
           (select string_agg(distinct trim(coalesce(p.address,'') || ', ' || coalesce(p.city,'')), ' | ')
              from properties p where p.client_id = c.id) addrs
    from clients c where c.client_code is not null order by c.client_code`);

  // group rows by sheet (need the state entry for the raw image path)
  const bySheet = {};
  let orphan = 0;
  for (const r of rows) {
    const e = (r.wm && byWmPage[`${r.wm}_${r.page}`]) || (r.df && byDfPage[`${r.df}_${r.page}`]);
    if (!e) { orphan++; continue; } // rows whose sheet was never stamped/downloaded
    (bySheet[e.key] ||= { key: e.key, wm: e.wm || r.df, local_file: e.local_file, rows: [] }).rows.push({
      id: r.id, row_index: r.row_index, facility: r.facility_name_read || '', address: r.address_read || '',
      status: r.assignment_status, confidence: r.confidence,
    });
  }
  const sheets = Object.values(bySheet);
  fs.writeFileSync(path.resolve(__dirname, 'data', '_rematch_payload.json'),
    JSON.stringify({ sheets, roster }, null, 1));
  console.log(`unmatched/low rows: ${rows.length} (${orphan} on never-stamped sheets, skipped)`);
  console.log(`sheets to re-match: ${sheets.length} · roster: ${roster.length} coded clients`);
  for (const s of sheets) console.log(`  ${s.key}: ${s.rows.length} row(s) -> ${s.rows.map(r => r.facility.slice(0, 22)).join(' | ')}`);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
