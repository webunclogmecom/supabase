// detect_grid.js : reusable printed-grid detector for the DERM Section-B table. Scans the left
// (Section B) columns for strong horizontal printed lines via dark-pixel-density projection, collapses
// thick runs to one line each, and returns them top-to-bottom. Works on the pre-printed form grid
// (present on both handwritten CamScanner scans and typed sheets) -- far more reliable than vision
// position estimation. Exported so the Window-fix script can reuse it.
const { decode } = require('./lib/crop');

// returns [{y_pct, score}] for horizontal lines with dark-density >= thresh within [y0Pct,y1Pct] x xRangePct
function detectLines(img, y0Pct, y1Pct, xRangePct, thresh = 0.5, lumThresh = 150) {
  const { width: W, height: H, data } = img;
  const lum = i => 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2];
  const x0 = Math.round(W * xRangePct[0] / 100), x1 = Math.round(W * xRangePct[1] / 100);
  const yLo = Math.max(0, Math.round(H * y0Pct / 100)), yHi = Math.min(H - 1, Math.round(H * y1Pct / 100));
  const rowScore = y => { let d = 0; for (let x = x0; x < x1; x++) if (lum((y * W + x) * 4) < lumThresh) d++; return d / (x1 - x0); };
  const lines = []; let run = null;
  for (let y = yLo; y <= yHi; y++) {
    const s = rowScore(y);
    if (s >= thresh) { if (!run) run = { bestY: y, bestS: s }; else if (s > run.bestS) { run.bestY = y; run.bestS = s; } }
    else if (run) { lines.push(run); run = null; }
  }
  if (run) lines.push(run);
  return lines.map(l => ({ y_pct: 100 * l.bestY / H, score: l.bestS }));
}

module.exports = { detectLines };

// CLI test mode: node detect_grid.js <imgPath> [xEndPct]
if (require.main === module) {
  const imgPath = process.argv[2];
  const xEnd = parseFloat(process.argv[3] || '37');
  const img = decode(imgPath);
  console.log(`${imgPath}  dims ${img.width}x${img.height}`);
  for (const th of [0.6, 0.5, 0.4]) {
    const lines = detectLines(img, 20, 70, [3, xEnd], th);
    console.log(`\n-- thresh ${th}: ${lines.length} lines --`);
    let prev = null;
    for (const l of lines) {
      const gap = prev != null ? (l.y_pct - prev).toFixed(2) : '-';
      console.log(`  y=${l.y_pct.toFixed(2)}%  score=${l.score.toFixed(2)}  gap=${gap}`);
      prev = l.y_pct;
    }
  }
}
