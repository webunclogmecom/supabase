// build_verify_wf_retry.js : generate data/gen_verify_wf.js for a specific list of out_png keys
// (used to retry verify passes that failed mid-batch, e.g. due to a rate/session limit).
const fs = require('fs');
const path = require('path');
const D = path.resolve(__dirname, 'data');
const KEYS = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const state = JSON.parse(fs.readFileSync(path.join(D, 'stamp_state.json'), 'utf8'));
const byOut = new Map(state.map(s => [s.out_png, s]));
const sheets = KEYS.map(k => {
  const s = byOut.get(k);
  if (!s) { console.error('WARN: no state for', k); return null; }
  return { key: s.out_png, stamped: s.out_png, gdo_x_pct: s.gdo_x_pct, codes: s.stamps.map(x => ({ code: x.code, address: x.address })) };
}).filter(Boolean);
const tmpl = fs.readFileSync(path.resolve(__dirname, 'verify_wf.js'), 'utf8');
const marker = 'const SHEETS = []';
fs.writeFileSync(path.join(D, 'gen_verify_wf.js'), tmpl.replace(marker, 'const SHEETS = ' + JSON.stringify(sheets)));
console.log('generated retry batch: ' + sheets.length + ' images, ' + sheets.reduce((a, s) => a + s.codes.length, 0) + ' codes');
