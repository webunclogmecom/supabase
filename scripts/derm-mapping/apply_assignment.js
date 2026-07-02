// apply_assignment.js <windowNumber> [--apply] : place each client code at its TRUE physical row
// (from the vision assignment in data/_assign_result_<n>.json) using the measured row centers in
// data/_assign_payload_<n>.json, then re-render. This supersedes row_index-based placement, which is
// wrong whenever a physical row was skipped during extraction (e.g. 824949 p2 row 2).
const fs = require('fs');
const path = require('path');
const { render } = require('./lib/stamp_render');

const n = parseInt(process.argv[2], 10);
const apply = process.argv.includes('--apply');
const D = path.resolve(__dirname, 'data');
const payload = JSON.parse(fs.readFileSync(path.join(D, `_assign_payload_${n}.json`), 'utf8'));
const results = JSON.parse(fs.readFileSync(path.join(D, `_assign_result_${n}.json`), 'utf8'));
const STATE_FILE = path.join(D, 'stamp_state_v3.json');
const state = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));

const payloadBy = Object.fromEntries(payload.map(p => [p.key, p]));
let changed = 0, flagged = [];
for (const res of results) {
  const p = payloadBy[res.key];
  const entry = state.find(e => e.key === res.key);
  if (!p || !entry) { console.log('skip', res.key, '(no payload/state)'); continue; }
  const centerFor = r => (p.rowCenters.find(c => c.phys_row === r) || {}).y_pct;
  const addrFor = code => (p.codes.find(c => c.code === code) || {}).address || '';

  const newStamps = [];
  for (const row of res.rows) {
    if (!row.assigned_code) continue;
    const y = centerFor(row.phys_row);
    if (y == null) { console.log(`  !! ${res.key}: no center for phys_row ${row.phys_row}`); continue; }
    newStamps.push({ code: row.assigned_code, y_pct: y, address: addrFor(row.assigned_code) });
  }
  newStamps.sort((a, b) => a.y_pct - b.y_pct);

  // report vs current
  const oldCodes = entry.stamps.map(s => s.code).sort().join(',');
  const newCodes = newStamps.map(s => s.code).sort().join(',');
  const posChange = newStamps.some(ns => { const o = entry.stamps.find(s => s.code === ns.code); return !o || Math.abs(o.y_pct - ns.y_pct) > 0.3; });
  const tag = (oldCodes !== newCodes) ? 'CODESET-CHANGED' : (posChange ? 'moved' : 'same');
  console.log(`${res.key}: ${newStamps.length} codes [${tag}]`);
  for (const ns of newStamps) {
    const o = entry.stamps.find(s => s.code === ns.code);
    console.log(`   ${ns.code.padEnd(10)} phys_row-> y=${ns.y_pct.toFixed(2)}  (was ${o ? o.y_pct.toFixed(2) : 'MISSING'})`);
  }
  if (res.rows_with_facility_but_no_code && res.rows_with_facility_but_no_code.length) {
    for (const r of res.rows_with_facility_but_no_code) {
      const rr = res.rows.find(x => x.phys_row === r);
      flagged.push(`${res.key} row ${r}: "${rr ? rr.facility_read : '?'}" / "${rr ? rr.address_read : ''}" (facility on sheet, no code)`);
    }
  }
  if (apply) {
    entry.stamps = newStamps;
    const base = entry.out_png.replace(/_\d+codes\.png$/, '');
    entry.out_png = `${base}_${newStamps.length}codes.png`;
    render(entry.local_file, entry.gdo_x_pct, entry.stamps, entry.out_png);
    changed++;
  }
}
if (apply) { fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2)); console.log(`\nAPPLIED: ${changed} sheets re-rendered`); }
else console.log('\n(dry run)');
console.log('\n--- facilities on sheet with NO code (Yannick fills, or data gap) ---');
for (const f of flagged) console.log('  ' + f);
