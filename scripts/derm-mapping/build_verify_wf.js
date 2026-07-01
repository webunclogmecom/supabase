// build_verify_wf.js [win...] : generate data/gen_verify_wf.js — verify_wf.js with the stamped images
// (from data/stamp_state.json) embedded. Optional window filter (2-digit strings) to batch.
const fs = require('fs');
const path = require('path');
const D = path.resolve(__dirname, 'data');
const state = JSON.parse(fs.readFileSync(path.join(D, 'stamp_state.json'), 'utf8'));
const wins = process.argv.slice(2).map(s => String(s).padStart(2, '0'));
const sheets = state
  .filter(s => s.stamps && s.stamps.length && (!wins.length || wins.includes(s.window)))
  .map(s => ({ key: s.out_png, stamped: s.out_png, gdo_x_pct: s.gdo_x_pct, codes: s.stamps.map(x => ({ code: x.code, address: x.address })) }));
const tmpl = fs.readFileSync(path.resolve(__dirname, 'verify_wf.js'), 'utf8');
const marker = 'const SHEETS = []';
if (!tmpl.includes(marker)) { console.error('ERR: marker not found in verify_wf.js'); process.exit(1); }
fs.writeFileSync(path.join(D, 'gen_verify_wf.js'), tmpl.replace(marker, 'const SHEETS = ' + JSON.stringify(sheets)));
console.log('generated data/gen_verify_wf.js: ' + sheets.length + ' stamped images' + (wins.length ? (' (windows ' + wins.join(',') + ')') : '') + ', ' + sheets.reduce((a, s) => a + s.codes.length, 0) + ' codes to verify');
