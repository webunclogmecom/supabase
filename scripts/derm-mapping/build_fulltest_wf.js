// build_fulltest_wf.js : generate data/gen_fulltest_wf.js — the full-fleet verification workflow.
// Embeds data/_fulltest_payload.json (110 sheets) and runs one OCR+placement verifier per sheet in
// sequential batches (gentle on rate limits). Written via a Node generator (NOT shell heredoc — the
// bash-escaping corruption lesson) and read back before launch.
const fs = require('fs');
const path = require('path');
const D = path.resolve(__dirname, 'data');
const payload = JSON.parse(fs.readFileSync(path.join(D, '_fulltest_payload.json'), 'utf8'));

const SCHEMA_STR = `{
  type: 'object', additionalProperties: false,
  properties: {
    rows_ocr: { type: 'array', items: { type: 'object', additionalProperties: false, properties: {
      row: { type: 'integer' }, facility: { type: 'string' }, address: { type: 'string' },
      red_code: { type: ['string','null'] } }, required: ['row','facility','address','red_code'] } },
    verdicts: { type: 'array', items: { type: 'object', additionalProperties: false, properties: {
      code: { type: 'string' },
      status: { type: 'string', enum: ['correct','misaligned','wrong_row','not_found','cannot_tell'] },
      on_row: { type: ['integer','null'] }, note: { type: 'string' } },
      required: ['code','status','on_row','note'] } },
    overall: { type: 'string', enum: ['all_correct','has_problem'] },
    notes: { type: 'string' },
  }, required: ['rows_ocr','verdicts','overall','notes'],
}`;

const script = `export const meta = {
  name: 'derm-fulltest-verify',
  description: 'Full-fleet OCR + placement verification of all stamped DERM sheets',
  phases: [{ title: 'Verify' }],
}

const PAYLOAD = ${JSON.stringify(payload)}

const SCHEMA = ${SCHEMA_STR}

function prompt(p) {
  const expLines = p.expected.map(e => '  - ' + e.code + '  ->  "' + e.facility + '" / "' + e.address + '"').join('\\n') || '  (none)'
  const known = p.missing_in_render.length ? '\\nKNOWN ISSUE (already logged, just confirm): these expected codes were NOT rendered on this image: ' + p.missing_in_render.join(', ') + '. Verify their rows are indeed unstamped; do not treat as a new finding.' : ''
  return \`You are ADVERSARIALLY verifying red client-code labels stamped on a Miami-Dade FOG eManifest sheet. Catch errors; do not rubber-stamp. Be slow and precise.

Stamped image: \${p.out_png} (use the Read tool).

STEP 1 — OCR the sheet yourself. Section B has physical facility row slots (usually 6; typed sheets have 5), numbered top to bottom. For EACH slot read the handwritten/printed Facility Name and Address (empty strings if blank). Trust YOUR reading of the image, not any assumption about row numbering.

STEP 2 — Locate every RED code label (like "062-TCE") in the left GDO column. For each, decide which physical row it sits on: it should be vertically centered on that row's facility-NAME writing line. If it sits on a boundary/divider line or closer to a neighbouring row's text, that is a problem.

STEP 3 — Judge. These codes are SUPPOSED to be on this sheet, each on the row whose facility/address matches:
\${expLines}
For each expected code give status:
  correct     = red label present, clearly seated on the row whose OCR content matches its facility/address
  misaligned  = right row, but visibly floating between rows / on the divider (ambiguous which row)
  wrong_row   = seated on a row whose content does NOT match the code's facility/address
  not_found   = expected but no red label with this code on the image
  cannot_tell = row content illegible (use sparingly)
Also report in notes: any red label whose code text is NOT in the expected list, any duplicate labels, and any OCR mismatch worth flagging.\${known}

overall = 'all_correct' only if every verdict is 'correct' (known-issue codes confirmed absent count as correct-confirmation, mention in notes).

IMPORTANT: if you crop/zoom, write temp files ONLY under the system temp dir — NEVER into the folder containing the image. Return ONLY the JSON.\`
}

phase('Verify')
const CHUNK = 15
const results = []
for (let i = 0; i < PAYLOAD.length; i += CHUNK) {
  const batch = PAYLOAD.slice(i, i + CHUNK)
  log('verify batch ' + (Math.floor(i / CHUNK) + 1) + '/' + Math.ceil(PAYLOAD.length / CHUNK) + ' (' + batch.length + ' sheets)')
  const out = await parallel(batch.map(p => () =>
    agent(prompt(p), { label: 'v:' + p.key, phase: 'Verify', schema: SCHEMA, effort: 'high' })
      .then(r => ({ key: p.key, ...r }))
      .catch(() => ({ key: p.key, overall: 'ERROR', verdicts: [], rows_ocr: [], notes: 'agent failed' }))
  ))
  results.push(...out.filter(Boolean))
}
return { results }
`;

fs.writeFileSync(path.join(D, 'gen_fulltest_wf.js'), script);
console.log('generated data/gen_fulltest_wf.js:', payload.length, 'sheets,', Math.ceil(payload.length / 15), 'batches, bytes:', script.length);
