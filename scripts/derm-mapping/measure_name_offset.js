// measure_name_offset.js <key> : for a given Window_03 sheet, compare where each code was STAMPED
// (y_pct in stamp_state) against where the actual handwritten facility NAME ink sits in that row's
// upper sub-cell. Detects the name-ink vertical centroid in the name column (right of the printed
// "Facility Name" label), so we can see if the stamp is systematically too high/low.
const fs = require('fs');
const path = require('path');
const { decode } = require('./lib/crop');
const { detectLines } = require('./detect_grid');

const key = process.argv[2];
const state = JSON.parse(fs.readFileSync(path.resolve(__dirname, 'data', 'stamp_state_v3.json'), 'utf8'));
const entry = state.find(e => e.key === key);
if (!entry) { console.error('no entry', key); process.exit(1); }
const img = decode(entry.local_file);
const { width: W, height: H, data } = img;
const lum = i => 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2];

// row boundaries from Section C
function rowBoundaries() {
  const lines = detectLines(img, 16, 72, [46, 60], 0.55).map(l => l.y_pct);
  let best = [];
  for (let i = 0; i < lines.length; i++) {
    const run = [lines[i]];
    for (let j = i + 1; j < lines.length; j++) {
      const gap = lines[j] - run[run.length - 1];
      if (gap >= 4.5 && gap <= 6.5) run.push(lines[j]);
      else if (gap < 4.5) continue; else break;
    }
    if (run.length > best.length) best = run;
  }
  return best.slice(0, 7);
}
const bounds = rowBoundaries();
const rh = (bounds[bounds.length - 1] - bounds[0]) / (bounds.length - 1);

function dividerFor(top, bot) {
  const cand = detectLines(img, top + (bot - top) * 0.2, top + (bot - top) * 0.78, [3, 40], 0.5);
  if (!cand.length) return top + (bot - top) * 0.5;
  const mid = top + (bot - top) * 0.5;
  cand.sort((a, b) => Math.abs(a.y_pct - mid) - Math.abs(b.y_pct - mid));
  return cand[0].y_pct;
}

// name-ink centroid in the name column (x 20-42%) within [top, divider]
function nameInkCenter(top, div) {
  const x0 = Math.round(W * 0.20), x1 = Math.round(W * 0.42);
  const yLo = Math.round(H * (top + 0.4) / 100), yHi = Math.round(H * (div - 0.15) / 100);
  let sum = 0, wsum = 0;
  for (let y = yLo; y <= yHi; y++) {
    let dark = 0;
    for (let x = x0; x < x1; x++) if (lum((y * W + x) * 4) < 110) dark++;
    sum += dark * y; wsum += dark;
  }
  return wsum > 20 ? { y_pct: 100 * (sum / wsum) / H, ink: wsum } : { y_pct: null, ink: wsum };
}

console.log(`${key}  dims ${W}x${H}  rowH ${rh.toFixed(2)}  boundaries: ${bounds.map(b => b.toFixed(1)).join(', ')}`);
for (let k = 1; k < bounds.length; k++) {
  const top = bounds[k - 1], bot = bounds[k];
  const div = dividerFor(top, bot);
  const midCell = (top + div) / 2;      // what I currently stamp at
  const ink = nameInkCenter(top, div);   // where the handwriting actually is
  console.log(`row ${k}: top=${top.toFixed(2)} div=${div.toFixed(2)} | mid-cell(stamped)=${midCell.toFixed(2)}  name-ink=${ink.y_pct ? ink.y_pct.toFixed(2) : 'n/a'} (ink ${ink.ink})  delta=${ink.y_pct ? (ink.y_pct - midCell).toFixed(2) : '-'}`);
}
console.log('\ncurrent stamps:');
for (const s of entry.stamps.slice().sort((a,b)=>a.y_pct-b.y_pct)) console.log(`  ${s.code.padEnd(10)} y=${s.y_pct.toFixed(2)}`);
