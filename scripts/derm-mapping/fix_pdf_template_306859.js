// One-off fix for manifest 306859 (w2-s2-p1/p2/p3), the only sheets in the whole 113-image dataset
// matching the typed-PDF-generated template (5 facility rows, "100X-Y" top-right number) instead of
// the standard 6-row handwritten CamScanner template. The calibrated ROW_HEIGHT_FULL_PCT=5.433 used
// everywhere else is specific to the 6-row template's physical spacing and does not apply here --
// this template's rows are taller (~7.1-7.9% each) and non-uniform between rows. Row centers below
// were measured directly from each page's own printed grid lines (see find_pdf_template_dividers.js
// + data/_pdf_template_rows.json) and mapped to the existing DB-confirmed codes by visual row order
// (verified by reading all 3 raw images). Every other sheet in stamp_state_v3.json is untouched.
const fs = require('fs');
const path = require('path');
const { render } = require('./lib/stamp_render');

const STATE_FILE = path.resolve(__dirname, 'data', 'stamp_state_v3.json');
const state = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));

// code -> corrected y_pct, per page. Derived from data/_pdf_template_rows.json's name_center_y_pct,
// row_index assigned by matching each stamp's code, in stored (ascending y_pct) order, against the
// facility row order read directly off the raw image.
const FIXES = {
  'w2-s2-p1': { '020-G7': 27.444, '076-TCE': 35.338, '024-GRO': 41.980, '205-SAS': 49.311, '028-HUM': 57.018 },
  'w2-s2-p2': { '109-RAB': 27.141, '010-CS': 35.139, '106-ALC': 41.751, '044-MP': 57.116 },
  'w2-s2-p3': { '242-WYN': 27.727, '226-JER': 35.714, '034-LG': 42.468, '056-STM': 49.935, '182-PAL': 57.857 },
};

let changed = 0;
for (const entry of state) {
  const fix = FIXES[entry.key];
  if (!fix) continue;
  let any = false;
  for (const st of entry.stamps) {
    if (fix[st.code] == null) { console.error(`!! ${entry.key}: no fix for stamp code ${st.code} -- leaving as-is`); continue; }
    const before = st.y_pct;
    st.y_pct = fix[st.code];
    console.log(`${entry.key} ${st.code}: ${before.toFixed(2)} -> ${st.y_pct.toFixed(2)}`);
    any = true;
  }
  if (any) {
    render(entry.local_file, entry.gdo_x_pct, entry.stamps, entry.out_png);
    changed++;
  }
}
fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
console.log(`\n${changed} sheets re-rendered (out of ${Object.keys(FIXES).length} targeted).`);
