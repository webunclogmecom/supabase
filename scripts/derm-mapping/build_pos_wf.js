// build_pos_wf.js <win> [win...] : generate data/gen_pos_wf.js — pos_workflow.js with the given
// windows' sheets embedded (so the positioning workflow runs via scriptPath with no args).
const fs = require('fs');
const path = require('path');
const D = path.resolve(__dirname, 'data');
const wins = process.argv.slice(2).map(Number).filter(n => n >= 1 && n <= 13);
if (!wins.length) { console.error('usage: node build_pos_wf.js <win 1..13> [win...]'); process.exit(1); }
const sheets = [];
for (const n of wins) {
  const d = JSON.parse(fs.readFileSync(path.join(D, 'sheets_' + String(n).padStart(2, '0') + '.json'), 'utf8'));
  for (const s of d.sheets) sheets.push(s);
}
const tmpl = fs.readFileSync(path.resolve(__dirname, 'pos_workflow.js'), 'utf8');
const marker = 'const SHEETS = []';
if (!tmpl.includes(marker)) { console.error('ERR: marker not found in pos_workflow.js'); process.exit(1); }
const embedded = tmpl.replace(marker, 'const SHEETS = ' + JSON.stringify(sheets));
fs.writeFileSync(path.join(D, 'gen_pos_wf.js'), embedded);
const imgs = sheets.reduce((a, s) => a + (s.local_files || []).filter(p => p && !String(p).startsWith('DL_FAIL')).length, 0);
console.log('generated data/gen_pos_wf.js: ' + sheets.length + ' sheets, ' + imgs + ' page-images from windows [' + wins.join(',') + ']');
