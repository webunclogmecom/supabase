// analyze_pdf_template_lines.js : for the typed-PDF-style sheets (manifest 306859), find every
// horizontal ruled line in the Section B table region via dark-pixel-density projection, so we can
// derive the real row geometry instead of reusing the handwritten template's ROW_HEIGHT_FULL_PCT.
const fs = require('fs');
const path = require('path');
const { decode } = require('./lib/crop');

const STATE_FILE = path.resolve(__dirname, 'data', 'stamp_state_v3.json');
const state = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
const entries = state.filter(x => x.wm === '306859').sort((a, b) => a.page - b.page);

function findLines(img, y0Pct, y1Pct, xRangePct) {
  const { width: W, height: H, data } = img;
  const lum = i => 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2];
  const x0 = Math.round(W * xRangePct[0] / 100), x1 = Math.round(W * xRangePct[1] / 100);
  const yLo = Math.max(0, Math.round(H * y0Pct / 100));
  const yHi = Math.min(H - 1, Math.round(H * y1Pct / 100));
  const rowScore = y => { let dark = 0; for (let x = x0; x < x1; x++) if (lum((y * W + x) * 4) < 150) dark++; return dark / (x1 - x0); };
  const scores = [];
  for (let y = yLo; y <= yHi; y++) scores.push({ y, s: rowScore(y) });
  // find local maxima above a threshold, collapsing runs of consecutive high-score rows into one line
  const THRESH = 0.5;
  const lines = [];
  let run = null;
  for (const { y, s } of scores) {
    if (s >= THRESH) {
      if (!run) run = { yStart: y, yEnd: y, bestY: y, bestS: s };
      else { run.yEnd = y; if (s > run.bestS) { run.bestS = s; run.bestY = y; } }
    } else if (run) {
      lines.push(run); run = null;
    }
  }
  if (run) lines.push(run);
  return lines.map(l => ({ y_pct: 100 * l.bestY / H, score: l.bestS, thickness_px: l.yEnd - l.yStart + 1 }));
}

for (const e of entries) {
  const img = decode(e.local_file);
  // scan a bit wider than the stored box to make sure we catch the table top/bottom edges
  const y0 = Math.max(0, e.box.y0Pct - 3);
  const y1 = Math.min(100, e.box.y1Pct + 8);
  const xRange = [8, 92]; // full table width, avoiding page margins
  const lines = findLines(img, y0, y1, xRange);
  console.log(`\n=== ${e.key} (page ${e.page}, ${e.stamps.length} stamps) === scan y[${y0.toFixed(1)}-${y1.toFixed(1)}]`);
  let prevY = null;
  for (const l of lines) {
    const gap = prevY != null ? (l.y_pct - prevY).toFixed(3) : '-';
    console.log(`  y=${l.y_pct.toFixed(3)}%  score=${l.score.toFixed(2)}  thick=${l.thickness_px}px  gap_from_prev=${gap}`);
    prevY = l.y_pct;
  }
  console.log('  current stamp y_pcts:', e.stamps.map(s => s.y_pct.toFixed(2)).join(', '));
}
