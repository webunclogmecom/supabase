// One-off fix for manifest 827989 page 3 (w1-s4-p3, top-right "1006-2") -- a second, independently
// discovered typed-PDF-generated sheet missed by the first classification pass (which only sampled
// 113 images via sub-agent judgment; this one was in the very first, rate-limited partial run and
// got marked is_typed_pdf_style:false). Unlike manifest 306859 (all 3 pages typed), this manifest is
// MIXED: pages 1-2 are the standard handwritten 6-row CamScanner template, but page 3 is a photograph
// of the typed 5-row DERM_V4.00 form (2 rows pre-typed, 3 rows hand-filled in the remaining blanks).
// Row centers measured the same way as fix_pdf_template_306859.js: real block-boundary + internal
// name/address-divider lines via dark-pixel-density projection on this page's own printed grid.
// Every other sheet is untouched.
const fs = require('fs');
const path = require('path');
const { render } = require('./lib/stamp_render');

const STATE_FILE = path.resolve(__dirname, 'data', 'stamp_state_v3.json');
const state = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
const entry = state.find(x => x.key === 'w1-s4-p3');
if (!entry) throw new Error('w1-s4-p3 not found in stamp_state_v3.json');

const FIX = { '062-TCE': 28.454, '070-TCE': 43.860, '069-TCE': 51.755, '214-MYK': 59.978 };
for (const st of entry.stamps) {
  if (FIX[st.code] == null) { console.error('!! no fix for stamp code', st.code); continue; }
  const before = st.y_pct;
  st.y_pct = FIX[st.code];
  console.log(`${st.code}: ${before.toFixed(2)} -> ${st.y_pct.toFixed(2)}`);
}
render(entry.local_file, entry.gdo_x_pct, entry.stamps, entry.out_png);
fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
console.log('re-rendered', entry.out_png);
