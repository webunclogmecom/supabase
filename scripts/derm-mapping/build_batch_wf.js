// build_batch_wf.js <win> [win...] : generate data/gen_match_wf.js — a copy of match_workflow.js with
// the given windows' sheets + the current gazetteer EMBEDDED (so the workflow runs via scriptPath with
// no args, sidestepping the arg-size limit). Run the generated file with the Workflow tool.
const fs = require('fs');
const path = require('path');
const gz = require('./lib/gazetteer');
const D = path.resolve(__dirname, 'data');
const wins = process.argv.slice(2).map(Number).filter(n => n >= 1 && n <= 13);
if (!wins.length) { console.error('usage: node build_batch_wf.js <win 1..13> [win...]'); process.exit(1); }
const sheets = [];
for (const n of wins) {
  const p = path.join(D, 'sheets_' + String(n).padStart(2, '0') + '.json');
  const d = JSON.parse(fs.readFileSync(p, 'utf8'));
  for (const s of d.sheets) sheets.push(s);
}
const gazData = gz.load();
const tmpl = fs.readFileSync(path.resolve(__dirname, 'match_workflow.js'), 'utf8');
const marker = "const A = typeof args === 'string' ? JSON.parse(args) : (args || {})\nconst SHEETS = (A && A.sheets) || []\nconst GAZ = (A && A.gazetteer) || { byAddr: {}, byName: {} }";
if (!tmpl.includes(marker)) { console.error('ERR: could not find the args block in match_workflow.js — did it change?'); process.exit(1); }
const embedded = tmpl.replace(marker, 'const A = { window: null }\nconst SHEETS = ' + JSON.stringify(sheets) + '\nconst GAZ = ' + JSON.stringify(gazData));
fs.writeFileSync(path.join(D, 'gen_match_wf.js'), embedded);
const gazN = Object.keys(gazData.byAddr || {}).length + Object.keys(gazData.byName || {}).length;
console.log('generated data/gen_match_wf.js: ' + sheets.length + ' sheets from windows [' + wins.join(',') + '], gazetteer ' + gazN + ' entries');
