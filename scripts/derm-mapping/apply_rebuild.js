// apply_rebuild.js <resultFile> [--apply] : split the rebuild-assignment workflow result per window,
// write each window's _assign_result_<n>.json (affected sheets only), run apply_assignment per window,
// then delete stale ticket PNGs no longer referenced by stamp_state_v3.json.
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const D = path.resolve(__dirname, 'data');
const APPLY = process.argv.includes('--apply');
const resultFile = process.argv[2];

const raw = JSON.parse(fs.readFileSync(resultFile, 'utf8'));
const results = raw.result ? raw.result.results : raw;
console.log('assignment results:', results.length, 'sheets');

const byWin = {};
for (const r of results) (byWin[r.win] ||= []).push(r);

for (const win of Object.keys(byWin).sort((a, b) => +a - +b)) {
  // apply_assignment expects {key, rows, rows_with_facility_but_no_code?, unplaced_codes?}
  const entries = byWin[win].map(r => ({ key: r.key, rows: r.rows, unplaced_codes: r.unplaced_codes || [], rows_with_facility_but_no_code: [] }));
  fs.writeFileSync(path.join(D, `_assign_result_${win}.json`), JSON.stringify(entries, null, 1));
  console.log(`window ${win}: ${entries.length} sheet(s) -> _assign_result_${win}.json`);
  const unplaced = byWin[win].flatMap(r => (r.unplaced_codes || []).map(c => `${r.key}:${c}`));
  if (unplaced.length) console.log(`  UNPLACED: ${unplaced.join(', ')}`);
  const cmd = `node apply_assignment.js ${win}${APPLY ? ' --apply' : ''}`;
  const out = execSync(cmd, { cwd: __dirname, encoding: 'utf8' });
  console.log(out.split('\n').filter(l => l.includes('[') || l.includes('APPLIED') || l.includes('dry')).join('\n'));
}

if (APPLY) {
  // stale-PNG cleanup across all windows
  const state = JSON.parse(fs.readFileSync(path.join(D, 'stamp_state_v3.json'), 'utf8'));
  const keep = new Set(state.map(e => path.basename(e.out_png)));
  const ROOT = 'C:/Users/FRED/Downloads/DERM_Stamped';
  let del = 0;
  for (const w of fs.readdirSync(ROOT).filter(d => /^Window_\d+$/.test(d))) {
    for (const f of fs.readdirSync(path.join(ROOT, w))) {
      if (/\.png$/i.test(f) && /^(ticket_|window\d+_sheet)/.test(f) && !keep.has(f)) {
        fs.unlinkSync(path.join(ROOT, w, f)); del++; console.log('deleted stale', w + '/' + f);
      }
    }
  }
  console.log(`stale PNGs deleted: ${del}`);
}
