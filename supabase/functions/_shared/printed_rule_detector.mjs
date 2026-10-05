// printed_rule_detector.mjs: the run-length printed-rule detector as ONE module, imported by the
// Node probe (scripts/probes/rev/detect_node.mjs) and by the edge function measure-generated-page.
//
// Transcribed 2026-09-14 from scripts/probes/rev/detect_node.js (itself a port of
// scripts/probes/derm_band_review/detect-run.js, the detector this estate validated against known
// truth; four earlier scorers were tried and rejected, see that folder's README). The extraction was
// done by a script, not by retyping: the function body is the old file's `detect` body with ONLY its
// first line changed, so the decoded image comes in as a parameter and the same bytes run in Deno
// and in Node. scripts/probes/generated_finisher/detect_core_test.mjs asserts the output is
// identical to the pre-extraction script's frozen output on a known scan.
//
// Input:  raw = {width, height, data: Uint8Array RGBA}, what jpeg-js decode(bytes, {useTArray:true})
//         returns. topPct / botPct (optional) bound the roster search, default 18 / 72.
// Output: {W, H, skew, rules: [{pct, run, kind}]} sorted by pct. `kind` is the detector's own
//         long/short label (run >= 0.80 = boundary) and is NOT a classification: the generated-sheet
//         matcher ignores it, and the Studio's classifier re-derives it from alternation.

const FULL_RUN = 0.80;
const MIN_RUN = 0.33;
const MIN_SEP_PP = 0.70;
const SLOPES = [-8, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 8].map((v) => v / 1000);

export function detectRules(raw, topPct = null, botPct = null) {
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
  // (2026-10-05: by counting, not by sorting each column; same value)
  const cut = new Float32Array(W);
  const hist = new Uint32Array(256);
  const nCol = yB >= yA ? ((yB - yA) >> 1) + 1 : 0, k = (nCol * 0.7) | 0;
  for (let x = x0; x < x1; x++) {
    hist.fill(0);
    for (let y = yA; y <= yB; y += 2) hist[L[y * W + x]]++;
    let p = 0;
    for (let seen = 0; p < 256; p++) { seen += hist[p]; if (seen > k) break; }
    cut[x] = p - Math.max(9, p * 0.1);
  }

  // 2026-10-05: the dark test is computed ONCE per pixel, not once per slope pass (16 passes), and the
  // winning pass is kept rather than recomputed. Same output, about a third of the CPU: a 7-megapixel
  // scan exceeded the edge runtime's 2 s CPU limit (measure-page-reference, ticket-829216 p1).
  // A pixel is dark when it, or the pixel above or below it, is under its column's paper cut.
  const DK = new Uint8Array(W * H);
  for (let y = 1; y < H - 1; y++) {
    for (let x = x0, p = y * W + x0; x < x1; x++, p++) {
      const t = cut[x];
      if (L[p] < t || L[p - W] < t || L[p + W] < t) DK[p] = 1;
    }
  }

  const profileFor = (slope) => {
    const rf = new Float32Array(H);
    // the row offset of each column for this slope, and its pixel index relative to the row start
    const off = new Int32Array(x1), rel = new Int32Array(x1);
    let lo = 0, hi = 0;
    for (let x = x0; x < x1; x++) {
      off[x] = (slope * (x - xMid)) | 0; rel[x] = off[x] * W + x;
      if (off[x] < lo) lo = off[x]; if (off[x] > hi) hi = off[x];
    }
    for (let y = yA - 12; y <= yB + 12; y++) {
      if (y < 1 || y >= H - 1) continue;
      let best = 0, cur = 0;
      if (y + lo >= 1 && y + hi < H - 1) {          // every column of this row is inside the image
        const base = y * W;
        for (let x = x0; x < x1; x++) {
          if (DK[base + rel[x]]) { cur++; if (cur > best) best = cur; } else cur = 0;
        }
      } else {
        for (let x = x0; x < x1; x++) {
          const yy = y + off[x];
          if (yy < 1 || yy >= H - 1) { cur = 0; continue; }
          if (DK[yy * W + x]) { cur++; if (cur > best) best = cur; } else cur = 0;
        }
      }
      rf[y] = best / span;
    }
    return rf;
  };

  let bestSlope = 0, bestScore = -1, rf = null;
  for (const s of SLOPES) {
    const prof = profileFor(s);
    let n = 0;
    for (let y = yA - 12; y <= yB + 12; y++) if (prof[y] >= FULL_RUN) n++;
    if (n > bestScore || (n === bestScore && Math.abs(s) < Math.abs(bestSlope))) {
      bestScore = n; bestSlope = s; rf = prof;
    }
  }

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
