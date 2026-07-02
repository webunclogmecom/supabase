// build_verify_payload.js <windowNumber> : build the payload for adversarial verification of the
// RENDERED stamped images. For each sheet, list the rendered PNG and the expected {code -> facility,
// address} that should appear (from the vision assignment). The verifier independently reads which
// facility each red code lands next to and checks it against this expectation.
const fs = require('fs');
const path = require('path');
const D = path.resolve(__dirname, 'data');

const n = parseInt(process.argv[2], 10);
const results = JSON.parse(fs.readFileSync(path.join(D, `_assign_result_${n}.json`), 'utf8'));
const state = JSON.parse(fs.readFileSync(path.join(D, 'stamp_state_v3.json'), 'utf8'));
const stateBy = Object.fromEntries(state.filter(e => e.window === String(n).padStart(2, '0')).map(e => [e.key, e]));

const payload = [];
for (const res of results) {
  const entry = stateBy[res.key];
  if (!entry) continue;
  const expected = res.rows
    .filter(r => r.assigned_code)
    .map(r => ({ code: r.assigned_code, facility: r.facility_read, address: r.address_read, phys_row: r.phys_row }));
  payload.push({ key: res.key, wm: res.wm || entry.wm, out_png: entry.out_png, expected });
}
const out = path.join(D, `_verify_payload_${n}.json`);
fs.writeFileSync(out, JSON.stringify(payload, null, 2));
console.log('wrote', out);
console.log(JSON.stringify(payload.map(p => ({ key: p.key, codes: p.expected.length })), null, 0));
