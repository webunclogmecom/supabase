// For each of the 3 PDF-style pages (manifest 306859), find the 6 block-boundary lines and, within
// each of the 5 blocks, the internal "Facility Name" / "Complete Facility Address" divider line, via
// dark-pixel-density projection on the real printed grid. Outputs the name-row center y_pct per row
// (row_index 1-5), which is where the GDO code should be vertically placed.
const fs = require('fs');
const path = require('path');
const { decode } = require('./lib/crop');
const { rotate90cw } = require('./lib/rotate90cw');

function rowScore(img, y, xRangePct) {
  const { width: W, data } = img;
  const lum = i => 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2];
  const x0 = Math.round(W * xRangePct[0] / 100), x1 = Math.round(W * xRangePct[1] / 100);
  let dark = 0; for (let x = x0; x < x1; x++) if (lum((y * W + x) * 4) < 150) dark++;
  return dark / (x1 - x0);
}

function findLines(img, y0Pct, y1Pct, xRangePct, thresh) {
  const { height: H } = img;
  const yLo = Math.max(0, Math.round(H * y0Pct / 100)), yHi = Math.min(H - 1, Math.round(H * y1Pct / 100));
  const lines = []; let run = null;
  for (let y = yLo; y <= yHi; y++) {
    const s = rowScore(img, y, xRangePct);
    if (s >= thresh) { if (!run) run = { bestY: y, bestS: s }; else if (s > run.bestS) { run.bestY = y; run.bestS = s; } }
    else if (run) { lines.push(run); run = null; }
  }
  if (run) lines.push(run);
  return lines.map(l => ({ y_pct: 100 * l.bestY / H, score: l.bestS }));
}

// Find the single strongest internal divider strictly between two boundary lines (weaker signal
// than the outer block borders, so use a lower threshold and just take the max-scoring row).
function findDivider(img, yTopPct, yBotPct, xRangePct) {
  const { height: H } = img;
  const yLo = Math.round(H * (yTopPct + 0.5) / 100), yHi = Math.round(H * (yBotPct - 0.5) / 100);
  let bestY = null, bestS = -1;
  for (let y = yLo; y <= yHi; y++) {
    const s = rowScore(img, y, xRangePct);
    if (s > bestS) { bestS = s; bestY = y; }
  }
  return { y_pct: 100 * bestY / H, score: bestS };
}

const PAGES = [
  { key: 'w2-s2-p1', file: 'data/images/w02/s02_p1.jpeg', rotate: false },
  { key: 'w2-s2-p2', file: 'data/images/w02/s02_p2.jpeg', rotate: true },
  { key: 'w2-s2-p3', file: 'data/images/w02/s02_p3.jpeg', rotate: false },
];

const results = {};
for (const p of PAGES) {
  let imgFile = p.file;
  if (p.rotate) {
    imgFile = path.resolve(__dirname, 'data', 'crops', '_tmp_rot_' + p.key + '.jpg');
    rotate90cw(p.file, imgFile);
  }
  const img = decode(imgFile);
  const xRange = [8, 92];
  const boundaries = findLines(img, 20, 68, xRange, 0.5).map(l => l.y_pct);
  console.log(`\n${p.key}: ${boundaries.length} boundaries found:`, boundaries.map(v => v.toFixed(3)).join(', '));
  if (boundaries.length !== 6) { console.log('  !! expected 6, got', boundaries.length, '-- inspect manually'); }
  const rows = [];
  for (let i = 0; i < boundaries.length - 1; i++) {
    const top = boundaries[i], bot = boundaries[i + 1];
    const div = findDivider(img, top, bot, [8, 40]); // narrower x-range: just section A/B text columns
    const nameCenterY = (top + div.y_pct) / 2;
    rows.push({ row_index: i + 1, top, divider: div.y_pct, bottom: bot, name_center_y_pct: nameCenterY, divider_score: div.score });
    console.log(`  row ${i + 1}: top=${top.toFixed(3)} divider=${div.y_pct.toFixed(3)} (score ${div.score.toFixed(2)}) bottom=${bot.toFixed(3)} -> name_center=${nameCenterY.toFixed(3)}`);
  }
  results[p.key] = rows;
}
fs.writeFileSync(path.join(__dirname, 'data', '_pdf_template_rows.json'), JSON.stringify(results, null, 2));
console.log('\nwrote data/_pdf_template_rows.json');
