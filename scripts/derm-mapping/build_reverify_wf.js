// build_reverify_wf.js : generate data/gen_reverify_wf.js — dual adversarial verification of the
// rebuilt sheets. Two independent voters per sheet, same strict OCR+placement criteria as the
// full-fleet pass, pointed at the NEW renders with the UPDATED expected sets.
const fs = require('fs');
const path = require('path');
const D = path.resolve(__dirname, 'data');
const rebuildSet = new Set(JSON.parse(fs.readFileSync(path.join(D, '_rebuild_set.json'), 'utf8')));
const payload = JSON.parse(fs.readFileSync(path.join(D, '_fulltest_payload.json'), 'utf8'))
  .filter(p => rebuildSet.has(p.key));

const SCHEMA_STR = `{
  type: 'object', additionalProperties: false,
  properties: {
    verdicts: { type: 'array', items: { type: 'object', additionalProperties: false, properties: {
      code: { type: 'string' },
      status: { type: 'string', enum: ['correct','misaligned','wrong_row','not_found','cannot_tell'] },
      on_row: { type: ['integer','null'] }, note: { type: 'string' } },
      required: ['code','status','on_row','note'] } },
    overall: { type: 'string', enum: ['all_correct','has_problem'] },
    notes: { type: 'string' },
  }, required: ['verdicts','overall','notes'],
}`;

const script = `export const meta = {
  name: 'derm-reverify-rebuilt',
  description: 'Dual adversarial verification of the rebuilt DERM sheets',
  phases: [{ title: 'Reverify' }],
}

const PAYLOAD = ${JSON.stringify(payload.map(p => ({ key: p.key, out_png: p.out_png, expected: p.expected, missing: p.missing_in_render })))}

const SCHEMA = ${SCHEMA_STR}

function prompt(p, voter) {
  const expLines = p.expected.map(e => '  - ' + e.code + '  ->  "' + e.facility + '" / "' + e.address + '"').join('\\n') || '  (none)'
  const known = p.missing.length ? '\\nKNOWN (deliberate): ' + p.missing.join(', ') + ' are matched in the DB but their facility rows are NOT physically on this page — confirm they are absent, do not count as findings.' : ''
  return \`ADVERSARIAL verification (voter \${voter}) of red client-code labels on a stamped DERM sheet. Your job is to CATCH mistakes. Be strict.

Image: \${p.out_png} (Read tool; any temp crops go ONLY to the system temp dir).

OCR each physical facility row yourself, locate every red code label, and judge each expected code:
\${expLines}
status: correct (seated on the row whose content matches its facility/address) | misaligned (right row but floating/on a divider) | wrong_row | not_found | cannot_tell. A label closer to a neighbouring row's text than its own is NOT correct. Also flag unexpected/duplicate labels in notes.\${known}

overall='all_correct' only if every expected code is 'correct'. Return ONLY the JSON.\`
}

phase('Reverify')
const CHUNK = 14
const jobs = []
for (const p of PAYLOAD) for (const v of [1, 2]) jobs.push({ p, v })
const results = []
for (let i = 0; i < jobs.length; i += CHUNK) {
  const batch = jobs.slice(i, i + CHUNK)
  log('reverify batch ' + (Math.floor(i / CHUNK) + 1) + '/' + Math.ceil(jobs.length / CHUNK))
  const out = await parallel(batch.map(({ p, v }) => () =>
    agent(prompt(p, v), { label: 'rv:' + p.key + '#' + v, phase: 'Reverify', schema: SCHEMA, effort: 'high' })
      .then(r => ({ key: p.key, voter: v, ...r }))
      .catch(() => ({ key: p.key, voter: v, overall: 'ERROR', verdicts: [], notes: 'agent failed' }))
  ))
  results.push(...out.filter(Boolean))
}
return { results }
`;

fs.writeFileSync(path.join(D, 'gen_reverify_wf.js'), script);
console.log('generated:', payload.length, 'sheets x 2 voters =', payload.length * 2, 'checks; bytes:', script.length);
