// apply_verify.js <verify-result.json> : apply the verify pass's corrected y per code to data/stamp_state.json,
// re-render the affected stamped images, and save the updated state (so a 2nd verify iteration can run).
const fs = require('fs');
const path = require('path');
const { render } = require('./lib/stamp_render');
const D = path.resolve(__dirname, 'data');
const raw = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const verifs = (raw.result && raw.result.verifications) || raw.verifications || [];
const byKey = {};
for (const v of verifs) { const map = {}; for (const c of (v.corrections || [])) if (typeof c.y_pct === 'number') map[String(c.code).trim()] = c.y_pct; byKey[v.key] = map; }
const state = JSON.parse(fs.readFileSync(path.join(D, 'stamp_state.json'), 'utf8'));
let changed = 0, moved = 0, reRendered = 0;
for (const s of state) {
  const corr = byKey[s.out_png];
  if (!corr || !s.stamps || !s.stamps.length) continue;
  let any = false;
  for (const st of s.stamps) {
    const ny = corr[String(st.code).trim()];
    if (typeof ny === 'number' && Math.abs(ny - st.y_pct) > 0.4) { st.y_pct = Math.max(2, Math.min(96, ny)); any = true; moved++; }
  }
  if (any) { try { render(s.local_file, s.gdo_x_pct, s.stamps, s.out_png); reRendered++; changed++; } catch (e) { console.error('re-render fail', s.out_png, e.message); } }
}
fs.writeFileSync(path.join(D, 'stamp_state.json'), JSON.stringify(state, null, 2));
console.log('applied verify: ' + moved + ' codes moved across ' + reRendered + ' re-rendered images; stamp_state.json updated');
