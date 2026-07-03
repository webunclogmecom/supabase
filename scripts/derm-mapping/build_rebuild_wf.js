// build_rebuild_wf.js : generate data/gen_rebuild_wf.js — the row-assignment workflow for the 47
// rebuild-set sheets. Combines the affected entries from every window's _assign_payload_<n>.json;
// each agent reads the RAW sheet and maps every confirmed code to its TRUE physical row (the w03
// method, fleet-wide).
const fs = require('fs');
const path = require('path');
const D = path.resolve(__dirname, 'data');
const rebuildSet = new Set(JSON.parse(fs.readFileSync(path.join(D, '_rebuild_set.json'), 'utf8')));

const entries = [];
for (let n = 1; n <= 13; n++) {
  const f = path.join(D, `_assign_payload_${n}.json`);
  if (!fs.existsSync(f)) continue;
  for (const e of JSON.parse(fs.readFileSync(f, 'utf8'))) if (rebuildSet.has(e.key)) entries.push({ ...e, win: n });
}
if (entries.length !== rebuildSet.size) {
  const have = new Set(entries.map(e => e.key));
  console.error('MISSING payload entries for:', [...rebuildSet].filter(k => !have.has(k)).join(', '));
}

const SCHEMA_STR = `{
  type: 'object', additionalProperties: false,
  properties: {
    rows: { type: 'array', items: { type: 'object', additionalProperties: false, properties: {
      phys_row: { type: 'integer' }, facility_read: { type: 'string' }, address_read: { type: 'string' },
      assigned_code: { type: ['string','null'] } },
      required: ['phys_row','facility_read','address_read','assigned_code'] } },
    unplaced_codes: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' },
  }, required: ['rows','unplaced_codes','notes'],
}`;

const script = `export const meta = {
  name: 'derm-rebuild-assign',
  description: 'Assign every confirmed code to its true physical row on the rebuild-set sheets',
  phases: [{ title: 'Assign' }],
}

const ENTRIES = ${JSON.stringify(entries)}

const SCHEMA = ${SCHEMA_STR}

function prompt(p) {
  return \`You are mapping known client codes to the correct PHYSICAL row on a Miami-Dade FOG eManifest sheet. Precision matters: a code on the wrong row is a compliance error.

Raw sheet image: \${p.local_file} (use the Read tool; temp crops go to the system temp dir ONLY).

Section B has \${p.phys_rows} physical row slots, numbered 1 (top) to \${p.phys_rows} (bottom). Each slot: a Facility Name line + a Complete Facility Address line. Some slots may be blank.

Codes to place (each belongs to exactly ONE physical row; the facility/address on file is given):
\${p.codes.map(c => '  - ' + c.code + ': ' + c.facility + ' | ' + c.address).join('\\n')}

1. Read EVERY slot 1..\${p.phys_rows} top to bottom; report the facility + address you see (empty strings if blank).
2. For each slot set assigned_code to the ONE code whose facility/address matches what is written there, else null. Addresses are the strongest signal; handwritten GDO-box numbers often equal the numeric part of the code (e.g. 028 = 028-HUM) — use them as corroboration.
3. A code with no matching row goes in unplaced_codes. Never assign the same code to two rows. If two rows both plausibly fit a code, put it in unplaced_codes and explain in notes.

Return ONLY the JSON.\`
}

phase('Assign')
const CHUNK = 12
const results = []
for (let i = 0; i < ENTRIES.length; i += CHUNK) {
  const batch = ENTRIES.slice(i, i + CHUNK)
  log('assign batch ' + (Math.floor(i / CHUNK) + 1) + '/' + Math.ceil(ENTRIES.length / CHUNK))
  const out = await parallel(batch.map(p => () =>
    agent(prompt(p), { label: 'as:' + p.key, phase: 'Assign', schema: SCHEMA, effort: 'high' })
      .then(r => ({ key: p.key, win: p.win, ...r }))
      .catch(() => null)
  ))
  results.push(...out.filter(Boolean))
}
return { results }
`;

fs.writeFileSync(path.join(D, 'gen_rebuild_wf.js'), script);
console.log('generated data/gen_rebuild_wf.js:', entries.length, 'sheets, bytes:', script.length);
