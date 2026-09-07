// Node port of scripts/probes/derm_band_review/detect-run.js (the run-length detector that this
// estate validated against known truth; four earlier scorers were tried and rejected, see that
// folder's README). Ported so it can run without a browser. NOT retyped from memory: the
// constants, the per-column paper level, the shear search, the NMS and the capped-plateau
// refinement are all transcribed from that file.
//
// USE: node detect_node.js <jpeg-path> [topPct] [botPct]
// It prints the detected rules. ALWAYS run it against a page whose truth you already know before
// believing it on a page you do not: a detector with no positive control is an untested instrument.
const fs = require('fs');
const jpeg = require('jpeg-js');

const FULL_RUN = 0.80;
const MIN_RUN = 0.33;
const MIN_SEP_PP = 0.70;
const SLOPES = [-8, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 8].map((v) => v / 1000);

function detect(path, topPct, botPct) {
  const raw = jpeg.decode(fs.readFileSync(path), { useTArray: true });
  const W = raw.width, H = raw.height, d = raw.data;
  const L = new Uint8Array(W * H);
  for (let i = 0, p = 0; p < W * H; p++, i += 4) {
    L[p] = (0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2]) | 0;
  }

  const yA = Math.max(2, Math.round(((topPct != null ? topPct : 18) - 5) / 100 * H));
  const yB = Math.min(H - 3, Math.round(((botPct != null ? botPct : 72) + 5) / 100 * H));
  const x0 = Math.floor(W * 0.02), x1 = Math.floor(W * 0.92), span = x1 - x0;
  const xMid = (x0 + x1) / 2;

  // per-column paper level: 70th percentile down the roster, so a column carrying a vertical
  // table line still resolves to paper rather than to the line
  const cut = new Float32Array(W);
  for (let x = x0; x < x1; x++) {
    const col = [];
    for (let y = yA; y <= yB; y += 2) col.push(L[y * W + x]);
    col.sort((a, b) => a - b);
    const p = col[(col.length * 0.7) | 0];
    cut[x] = p - Math.max(9, p * 0.1);
  }

  const profileFor = (slope) => {
    const rf = new Float32Array(H);
    for (let y = yA - 12; y <= yB + 12; y++) {
      if (y < 1 || y >= H - 1) continue;
      let best = 0, cur = 0;
      for (let x = x0; x < x1; x++) {
        const yy = y + ((slope * (x - xMid)) | 0);
        if (yy < 1 || yy >= H - 1) { cur = 0; continue; }
        const t = cut[x];
        const dark = L[yy * W + x] < t || L[(yy - 1) * W + x] < t || L[(yy + 1) * W + x] < t;
        if (dark) { cur++; if (cur > best) best = cur; } else cur = 0;
      }
      rf[y] = best / span;
    }
    return rf;
  };

  let bestSlope = 0, bestScore = -1;
  for (const s of SLOPES) {
    const rf = profileFor(s);
    let n = 0;
    for (let y = yA - 12; y <= yB + 12; y++) if (rf[y] >= FULL_RUN) n++;
    if (n > bestScore || (n === bestScore && Math.abs(s) < Math.abs(bestSlope))) {
      bestScore = n; bestSlope = s;
    }
  }
  const rf = profileFor(bestSlope);

  const sep = Math.max(3, Math.round(H * MIN_SEP_PP / 100));
  const cand = [];
  for (let y = yA - 12; y <= yB + 12; y++) if (rf[y] >= MIN_RUN) cand.push(y);
  cand.sort((a, b) => rf[b] - rf[a]);
  const taken = [];
  for (const y of cand) {
    if (taken.some((t) => Math.abs(t - y) < sep)) continue;
    taken.push(y);
  }

  const lim = Math.max(2, Math.round(H * MIN_SEP_PP / 200));
  const rules = taken.map((y) => {
    const v = rf[y];
    let a = y, b = y;
    while (a > 1 && y - a < lim && rf[a - 1] >= v - 0.03) a--;
    while (b < H - 2 && b - y < lim && rf[b + 1] >= v - 0.03) b++;
    const mid = (a + b) / 2;
    return { pct: +(mid / H * 100).toFixed(3), run: +v.toFixed(3), kind: v >= FULL_RUN ? 'boundary' : 'divider' };
  }).sort((p, q) => p.pct - q.pct);

  return { W, H, skew: bestSlope, rules };
}

const [, , path, top, bot] = process.argv;
const r = detect(path, top ? +top : null, bot ? +bot : null);
console.log(`${path}  ${r.W}x${r.H}  skew ${r.skew}`);
for (const x of r.rules) console.log(`  ${String(x.pct).padStart(7)}  run ${x.run.toFixed(3)}  ${x.kind}`);
