// build_locate_wf.js <win> [win...] : generate data/gen_locate_wf.js with the given windows' page
// images embedded (locate_box_wf.js template), for the coarse Section-B box pass.
const fs = require('fs');
const path = require('path');
const D = path.resolve(__dirname, 'data');
const wins = process.argv.slice(2).map(Number).filter(n => n >= 1 && n <= 13);
if (!wins.length) { console.error('usage: node build_locate_wf.js <win 1..13> [win...]'); process.exit(1); }
const images = [];
for (const n of wins) {
  const d = JSON.parse(fs.readFileSync(path.join(D, 'sheets_' + String(n).padStart(2, '0') + '.json'), 'utf8'));
  for (const s of d.sheets) (s.local_files || []).forEach((p, i) => {
    if (!p || String(p).startsWith('DL_FAIL')) return;
    images.push({ key: s.label + '-p' + (i + 1), local_file: p });
  });
}
const tmpl = fs.readFileSync(path.resolve(__dirname, 'locate_box_wf.js'), 'utf8');
const marker = 'const IMAGES = []';
fs.writeFileSync(path.join(D, 'gen_locate_wf.js'), tmpl.replace(marker, 'const IMAGES = ' + JSON.stringify(images)));
console.log('generated data/gen_locate_wf.js: ' + images.length + ' page-images from windows [' + wins.join(',') + ']');
