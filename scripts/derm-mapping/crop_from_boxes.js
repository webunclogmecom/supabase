// crop_from_boxes.js <locate-result.json> : crop each image to its coarse Section-B box (at native
// resolution) and write data/crops_all.json (key, local_file, cropped_file, box) for the fine pass.
const fs = require('fs');
const path = require('path');
const { cropPct } = require('./lib/crop');
const D = path.resolve(__dirname, 'data');
const CROPDIR = path.join(D, 'crops');
fs.mkdirSync(CROPDIR, { recursive: true });
const raw = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const boxes = (raw.result && raw.result.boxes) || raw.boxes || [];
const out = [];
let fails = 0;
for (const b of boxes) {
  if (typeof b.y0_pct !== 'number' || typeof b.y1_pct !== 'number' || typeof b.x1_pct !== 'number') { fails++; continue; }
  const croppedFile = path.join(CROPDIR, b.key.replace(/[^a-z0-9-]/gi, '_') + '.jpg');
  try {
    const box = cropPct(b.local_file, { x0Pct: 0, y0Pct: b.y0_pct, x1Pct: b.x1_pct, y1Pct: b.y1_pct }, croppedFile);
    out.push({ key: b.key, local_file: b.local_file, cropped_file: croppedFile.replace(/\\/g, '/'), box });
  } catch (e) { console.error('crop fail', b.key, e.message); fails++; }
}
fs.writeFileSync(path.join(D, 'crops_all.json'), JSON.stringify(out, null, 2));
console.log('cropped ' + out.length + ' images (' + fails + ' fails) -> data/crops/');
