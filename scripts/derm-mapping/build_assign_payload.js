// build_assign_payload.js <windowNumber> : for each sheet in a window, compute the physical row grid
// (6 boundaries -> per-row name-line center %) from the printed lines, and gather the confirmed codes
// with their DB addresses. Writes data/_assign_payload_<n>.json for the vision assignment workflow,
// which will map each code to its true PHYSICAL row (DB row_index can't be trusted as a physical
// pointer when extraction skipped a physical row -- see 824949 p2).
const fs = require('fs');
const path = require('path');
const { decode } = require('./lib/crop');
const { detectLines } = require('./detect_grid');
const { q } = require('./lib/db');

const NAME_FRAC = 0.25;
const MAX_ROWS = 6; // DERM Section B always has 6 physical row slots

function rowBoundaries(img) {
  const lines = detectLines(img, 16, 72, [46, 60], 0.55).map(l => l.y_pct);
  let best = [];
  for (let i = 0; i < lines.length; i++) {
    const run = [lines[i]];
    for (let j = i + 1; j < lines.length; j++) {
      const gap = lines[j] - run[run.length - 1];
      if (gap >= 4.5 && gap <= 6.5) run.push(lines[j]);
      else if (gap < 4.5) continue;
      else break;
    }
    if (run.length > best.length) best = run;
  }
  return best.slice(0, MAX_ROWS + 1); // at most 7 lines = 6 rows
}

function dividerFor(img, top, bot) {
  const rh = bot - top;
  const cand = detectLines(img, top + rh * 0.2, top + rh * 0.78, [3, 40], 0.5);
  if (!cand.length) return null;
  const mid = top + rh * 0.5;
  cand.sort((a, b) => Math.abs(a.y_pct - mid) - Math.abs(b.y_pct - mid));
  return cand[0].y_pct;
}

(async () => {
  const n = parseInt(process.argv[2], 10);
  const STATE_FILE = path.resolve(__dirname, 'data', 'stamp_state_v3.json');
  const state = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
  const entries = state.filter(e => String(e.window) === String(n).padStart(2, '0'))
    .sort((a, b) => a.wm.localeCompare(b.wm) || a.page - b.page);
  const wms = [...new Set(entries.map(e => e.wm))];
  const dbrows = await q(`
    select m.white_manifest_number as wm, m.page, m.row_index, m.address_read, m.facility_name_read,
           m.assignment_status, m.confidence, c.client_code
    from derm.address_row_map m left join public.clients c on c.id = m.matched_client_id
    where m.white_manifest_number in (${wms.map(w => `'${w}'`).join(',')})
    order by m.white_manifest_number, m.page, m.row_index`);
  const dbBy = {};
  for (const r of dbrows) (dbBy[`${r.wm}_${r.page}`] ||= []).push(r);

  const payload = [];
  for (const e of entries) {
    const img = decode(e.local_file);
    const bounds = rowBoundaries(img);
    const rh = bounds.length > 1 ? (bounds[bounds.length - 1] - bounds[0]) / (bounds.length - 1) : 5.5;
    const rowCenters = [];
    for (let k = 1; k < bounds.length; k++) {
      const top = bounds[k - 1], bot = bounds[k];
      const div = dividerFor(img, top, bot);
      rowCenters.push({ phys_row: k, y_pct: +( div != null ? (top + div) / 2 : top + NAME_FRAC * rh ).toFixed(2) });
    }
    const codes = (dbBy[`${e.wm}_${e.page}`] || [])
      .filter(r => r.assignment_status === 'matched' && r.confidence === 'high' && r.client_code)
      .map(r => ({ code: r.client_code, address: r.address_read || '', facility: r.facility_name_read || '' }));
    payload.push({ key: e.key, wm: e.wm, page: e.page, local_file: e.local_file, phys_rows: rowCenters.length, rowCenters, codes });
  }
  const out = path.resolve(__dirname, 'data', `_assign_payload_${n}.json`);
  fs.writeFileSync(out, JSON.stringify(payload, null, 2));
  console.log('wrote', out);
  for (const p of payload) console.log(`  ${p.key}: ${p.phys_rows} phys rows, ${p.codes.length} codes`);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
