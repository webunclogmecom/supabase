// split_batch.js <resultFile> : read a batch match-workflow result (the Workflow task-output JSON,
// which wraps the return value under .result), split its sheets by window (parsed from label
// 'w<N>-s<M>'), write data/match_<nn>.json per window, and merge each sheet's confirmed
// gazetteer_add into data/gazetteer.json (so later batches learn from earlier ones).
const fs = require('fs');
const path = require('path');
const gz = require('./lib/gazetteer');
const D = path.resolve(__dirname, 'data');
const rf = process.argv[2];
if (!rf) { console.error('usage: node split_batch.js <workflow-result.json>'); process.exit(1); }
const raw = JSON.parse(fs.readFileSync(rf, 'utf8'));
const result = raw.result || raw; // task-output wraps the return under .result; allow a bare result too
if (!result || !Array.isArray(result.sheets)) { console.error('ERR: no result.sheets in ' + rf); process.exit(1); }
const byWin = {};
for (const s of result.sheets) {
  const m = /^w(\d+)-/.exec(s.label || '');
  const n = m ? Number(m[1]) : 0;
  (byWin[n] = byWin[n] || []).push(s);
}
let g = gz.load();
let merged = 0;
for (const n of Object.keys(byWin)) {
  const sheets = byWin[n];
  fs.writeFileSync(path.join(D, 'match_' + String(n).padStart(2, '0') + '.json'), JSON.stringify({ window: Number(n), sheets }, null, 2));
  for (const s of sheets) { gz.merge(g, s.gazetteer_add || []); merged += (s.gazetteer_add || []).length; }
}
gz.save(g);
const gazN = Object.keys(g.byAddr).length + Object.keys(g.byName).length;
console.log('split windows [' + Object.keys(byWin).map(Number).sort((a, b) => a - b).join(',') + ']; merged ' + merged + ' confirmed facilities; gazetteer now ' + gazN + ' entries');
