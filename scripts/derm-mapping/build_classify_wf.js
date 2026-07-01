// build_classify_wf.js <batchIndex> : generate data/gen_classify_wf.js for one batch of images from
// data/_classify_batches.json, to classify typed-PDF-style vs handwritten sheets.
const fs = require('fs');
const path = require('path');
const D = path.resolve(__dirname, 'data');
const batches = JSON.parse(fs.readFileSync(path.join(D, '_classify_batches.json'), 'utf8'));
const idx = parseInt(process.argv[2], 10);
const images = batches[idx];
if (!images) { console.error('bad batch index'); process.exit(1); }

const SCHEMA_STR = `{
  type: 'object', additionalProperties: false,
  properties: {
    is_typed_pdf_style: { type: 'boolean' },
    top_right_number: { type: 'string' },
    row_count_visible: { type: 'integer' },
  }, required: ['is_typed_pdf_style', 'top_right_number', 'row_count_visible'],
}`;

const script = `export const meta = { name: 'derm-detect-template', description: 'Classify DERM sheets: typed-PDF-style vs handwritten', phases: [{ title: 'Classify' }] }

const IMAGES = ${JSON.stringify(images)}

const SCHEMA = ${SCHEMA_STR}

function prompt(im) {
  return \`Look at this Miami-Dade FOG eManifest image: \${im.local_file} (use the Read tool).

There are TWO possible styles for this form:
(A) A HANDWRITTEN scan photographed with CamScanner (visible paper texture/shadows, cursive handwriting throughout, usually has a "Scanned with CamScanner" watermark at the bottom, and Section B ("Origination of Waste") has 6 facility row slots).
(B) A TYPED/PRINTED PDF-generated version (crisp black text, no handwriting in Section B's facility names/addresses, no CamScanner watermark, and a distinctive small number like "1003-1" or "1004-2" printed in the TOP-RIGHT corner of the page, near the DERM_V4.00 form-version text). Section B on THIS style often has fewer than 6 row slots (e.g. 5).

Report:
- is_typed_pdf_style: true if this image matches style (B), false if it's style (A)
- top_right_number: the exact text you see in the top-right corner near the form-version label (e.g. "1003-1"), or "" if none
- row_count_visible: how many facility row slots Section B actually has on this page (count the GDO#/Facility Name blocks, whether filled or blank)

Return ONLY the JSON.\`
}

phase('Classify')
const out = await parallel(IMAGES.map(im => () =>
  agent(prompt(im), { label: 'cls:' + im.key, phase: 'Classify', schema: SCHEMA, effort: 'high' })
    .then(r => ({ key: im.key, wm: im.wm, local_file: im.local_file, ...r }))
    .catch(() => null)
))
return { results: out.filter(Boolean) }
`;
fs.writeFileSync(path.join(D, 'gen_classify_wf.js'), script);
console.log('generated batch ' + idx + ': ' + images.length + ' images');
