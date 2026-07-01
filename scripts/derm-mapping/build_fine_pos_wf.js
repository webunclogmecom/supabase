// build_fine_pos_wf.js [key...] : generate data/gen_fine_pos_wf.js embedding crops from
// data/crops_all.json (optionally filtered to specific keys), for the fine per-row position pass.
const fs = require('fs');
const path = require('path');
const D = path.resolve(__dirname, 'data');
const all = JSON.parse(fs.readFileSync(path.join(D, 'crops_all.json'), 'utf8'));
const keys = process.argv.slice(2);
const crops = keys.length ? all.filter(c => keys.includes(c.key)) : all;
const tmpl = fs.readFileSync(path.resolve(__dirname, 'fine_pos_wf.js'), 'utf8');
const marker = 'const CROPS = []';
fs.writeFileSync(path.join(D, 'gen_fine_pos_wf.js'), tmpl.replace(marker, 'const CROPS = ' + JSON.stringify(crops)));
console.log('generated data/gen_fine_pos_wf.js: ' + crops.length + ' crops' + (keys.length ? (' (filtered to ' + keys.length + ' keys)') : ''));
