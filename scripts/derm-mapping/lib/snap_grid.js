// Snap a predicted row-boundary position to the nearest REAL printed horizontal line in the image,
// via a dark-pixel-density projection searched only within a small window around the prediction.
// This uses vision only to get "in the right neighborhood" (avoiding the ambiguity of blind global
// line detection) and pixels for the final precise answer (avoiding vision's continuous-estimate error).
const { decode } = require('./crop');

// img: decoded {width,height,data}. predictedYPct/searchRadiusPct: % of image height.
// xRangePct: [x0,x1] % of image width to scan (avoid far-right columns that may be empty/noisy).
// A true printed rule line is a THIN, SHARP spike (1-3px); dense handwriting is a BROAD dark blob
// spanning many consecutive rows. Require the peak to stand out from rows a few pixels away, so
// handwriting doesn't get mistaken for a table line.
function findNearestLine(img, predictedYPct, searchRadiusPct, xRangePct = [2, 96]) {
  const { width: W, height: H, data } = img;
  const lum = i => 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2];
  const x0 = Math.round(W * xRangePct[0] / 100), x1 = Math.round(W * xRangePct[1] / 100);
  const yLo = Math.max(0, Math.round(H * (predictedYPct - searchRadiusPct) / 100));
  const yHi = Math.min(H - 1, Math.round(H * (predictedYPct + searchRadiusPct) / 100));
  const rowScore = y => { let dark = 0; for (let x = x0; x < x1; x++) if (lum((y * W + x) * 4) < 130) dark++; return dark / (x1 - x0); };
  const scores = {};
  const score = y => (scores[y] !== undefined ? scores[y] : (scores[y] = rowScore(y)));
  const offset = Math.max(2, Math.round(H * 0.012)); // ~1.2% of page height: far enough to clear a rule line, close enough to still be "this row"
  let bestY = null, bestScore = -1, bestSharpness = -1;
  for (let y = yLo; y <= yHi; y++) {
    const s = score(y);
    if (s < 0.35) continue; // too faint to be a real line
    const above = score(Math.max(0, y - offset)), below = score(Math.min(H - 1, y + offset));
    const sharpness = s - Math.max(above, below); // how much darker this row is than a bit further away
    if (sharpness > bestSharpness || (sharpness === bestSharpness && s > bestScore)) { bestSharpness = sharpness; bestScore = s; bestY = y; }
  }
  // require a genuine peak (meaningfully darker than nearby rows) or fall back to the prediction
  if (bestY == null || bestSharpness < 0.15) return { y_pct: predictedYPct, snapped: false, score: bestScore, sharpness: bestSharpness };
  return { y_pct: 100 * bestY / H, snapped: true, score: bestScore, sharpness: bestSharpness };
}

module.exports = { findNearestLine, decode };
