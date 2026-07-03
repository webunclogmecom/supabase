// build_rematch_wf.js : generate data/gen_rematch_wf.js — full-roster re-match workflow for
// unmatched/low-confidence rows. One agent per sheet: OCR the actual handwriting of each listed row
// on the RAW image, then match against the full coded-client roster. STRICT: only propose a code on
// strong name+address evidence; ambiguity -> null.
const fs = require('fs');
const path = require('path');
const D = path.resolve(__dirname, 'data');
const { sheets, roster } = JSON.parse(fs.readFileSync(path.join(D, '_rematch_payload.json'), 'utf8'));

const SCHEMA_STR = `{
  type: 'object', additionalProperties: false,
  properties: {
    proposals: { type: 'array', items: { type: 'object', additionalProperties: false, properties: {
      id: { type: 'integer' },
      ocr_facility: { type: 'string' }, ocr_address: { type: 'string' },
      code: { type: ['string','null'] },
      confidence: { type: 'string', enum: ['high','medium','none'] },
      reason: { type: 'string' } },
      required: ['id','ocr_facility','ocr_address','code','confidence','reason'] } },
    notes: { type: 'string' },
  }, required: ['proposals','notes'],
}`;

const rosterLines = roster.map(r => `${r.code} | ${r.name}${r.status && r.status !== 'ACTIVE' && r.status !== 'RECURRING' ? ' [' + r.status + ']' : ''}${r.addrs ? ' | ' + r.addrs : ''}`).join('\n');

const script = `export const meta = {
  name: 'derm-rematch-full-roster',
  description: 'Re-match unmatched DERM sheet rows against the full client roster',
  phases: [{ title: 'Rematch' }],
}

const SHEETS = ${JSON.stringify(sheets)}

const ROSTER = ${JSON.stringify(rosterLines)}

const SCHEMA = ${SCHEMA_STR}

function prompt(s) {
  const rows = s.rows.map(r => '  - id=' + r.id + ' (extraction row ' + r.row_index + '): earlier read as "' + r.facility + '" / "' + r.address + '"').join('\\n')
  return \`You are matching handwritten facility rows on a Miami-Dade FOG eManifest sheet to known clients. Precision over recall: a WRONG match is far worse than no match.

Raw sheet image: \${s.local_file} (use the Read tool; zoom/crop to temp dir only if needed — NEVER write into the image's folder).

These rows on this sheet are currently UNMATCHED (an earlier pass only compared against a 2-week candidate list; you have the FULL roster):
\${rows}

STEP 1 — find each listed row on the sheet and OCR the facility name + address YOURSELF (the earlier read may be wrong/partial; trust the ink).

STEP 2 — match each against the FULL CLIENT ROSTER below (format: code | name | known addresses). Rules:
  - 'high' ONLY when the name clearly corresponds to a roster client (misspellings/abbreviations fine) AND the address agrees (same street number + street, or the roster address is missing but the name is unambiguous).
  - 'medium' when the name fits but the address disagrees/can't be read, or two roster clients are plausible (say which in reason).
  - 'none' (code=null) when nothing fits confidently, the row is illegible, or it isn't a client (e.g. our own company, a supplier, a facility we clearly don't serve).
  - NEVER force a match. If two candidates are close, that is 'medium' at best.

ROSTER (\${ROSTER.split('\\n').length} clients):
\${ROSTER}

Return ONLY the JSON with one proposal per listed id.\`
}

phase('Rematch')
const CHUNK = 12
const results = []
for (let i = 0; i < SHEETS.length; i += CHUNK) {
  const batch = SHEETS.slice(i, i + CHUNK)
  log('rematch batch ' + (Math.floor(i / CHUNK) + 1) + '/' + Math.ceil(SHEETS.length / CHUNK))
  const out = await parallel(batch.map(s => () =>
    agent(prompt(s), { label: 'rm:' + s.key, phase: 'Rematch', schema: SCHEMA, effort: 'high' })
      .then(r => ({ key: s.key, ...r }))
      .catch(() => ({ key: s.key, proposals: [], notes: 'agent failed' }))
  ))
  results.push(...out.filter(Boolean))
}
return { results }
`;

fs.writeFileSync(path.join(D, 'gen_rematch_wf.js'), script);
console.log('generated data/gen_rematch_wf.js:', sheets.length, 'sheets, bytes:', script.length);
