// FLEET-WIDE PRINTED-RULE DETECTOR for DERM address sheets.  v2
//
// A printed horizontal rule is the one thing on these pages that a band edge can safely land on:
// a rule is not text, so an edge sitting on a rule cannot be inside a line of text. That is the
// defect that leaked Wynd 28's street address to 226-JER (docs/migrations/2026-08-21_0651), and it
// is the only sound automated safety test found so far. Four scorers that reasoned about the
// GEOMETRY instead have been measured against known truth and rejected; see that migration header.
//
// ============================================================================================
// THE MEASUREMENT THAT MADE v2 POSSIBLE
// ============================================================================================
// Scoring a row by the LONGEST CONTIGUOUS HORIZONTAL RUN of dark pixels, over the FULL table
// width rather than the text column, produces a sharply bimodal distribution. Measured over the
// 30 pages that already carry hand-recorded rules, 358 detections:
//
//     run 0.40-0.50   108 detections      run 0.80-1.05   171 detections
//     run 0.50-0.80    28 detections   <- the gap
//
// The two clusters are two different printed objects:
//
//   run ~1.00  a SLOT BOUNDARY. It spans the entire form, across the FOG / Hydro / Gravity
//              columns on the right where no text is ever written.
//   run ~0.41  a MID-SLOT DIVIDER, between a client's "Facility Name" row and its "Complete
//              Facility Address" row. It stops at the first vertical column line.
//
// 🛑 THIS SETTLES THE AMBIGUITY THAT BLOCKED SNAPPING. docs/migrations/2026-08-20_1610 records
// that rules sit ~3.5pp apart while a client's slot is ~7.8pp, so "snap to the nearest rule" was
// a coin flip: on ticket-310607 one edge had candidates 1.82 and 2.34 away. The run length tells
// the two kinds apart directly, so a band edge can be required to sit on a FULL-WIDTH rule.
// Ink fraction, which the 2026-08-03 detector used, cannot: a dense line of text inks as much of
// the column as a rule does, which is why its margin was thin enough to fail on a light scan.
//
// ============================================================================================
// WHAT ELSE v2 CHANGES, AND WHY EACH ONE WAS NEEDED
// ============================================================================================
//  1. PER-COLUMN ADAPTIVE PAPER LEVEL. "Dark" is measured against each column's own paper, the
//     70th percentile of that column's luma down the roster. Survives the uneven illumination of
//     a photographed sheet and the low contrast of a dark scan, where one global threshold either
//     finds everything or nothing (the recorded ticket-831325 p1 failure: 4 rules where comparable
//     pages found 13).
//  2. SKEW SEARCH. v1 found 4 of 12 rules on ticket-311780 p2 with no obvious contrast problem.
//     A scan rotated by a fraction of a degree breaks a horizontal run into pieces, and the run
//     test is the whole basis of the method. v2 shears the sampling by a range of slopes and keeps
//     the one that maximises full-width hits. `skew_gain` records what the search bought, so a
//     page where it did nothing is visible rather than assumed.
//  3. NON-MAXIMUM SUPPRESSION instead of thresholded groups. v1 discarded any group thicker than
//     0.8pp, which silently DELETED real rules whenever the threshold was low enough for a rule's
//     shoulders to merge with nearby ink: on ticket-832487 p2 the loose variant reported the six
//     mid-slot dividers and none of the six slot boundaries, because every boundary group was too
//     thick to survive. A filter that removes the strongest evidence is worse than no filter.
//  4. CENTROID POSITIONING. v1 took the argmax row, and with one row of vertical tolerance that
//     is biased upward: every rule on ticket-832996 came out 0.14-0.28pp (1-2px) above its
//     recorded value, consistently. The centroid of the plateau removes the bias.
//
// Usage: node detect.js <inventory.json> <offset> <count> <outfile.json>
// Emits detect-run.js for the playwright browser_run_code tool; the heavy result is written to
// <outfile> through a Blob download, because the browser code context has neither require() nor
// dynamic import and the payload is far too large to return through the tool result.
const fs = require('fs');
const inv = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const OFFSET = Number(process.argv[3] || 0);
const COUNT = Number(process.argv[4] || 20);
const OUTFILE = (process.argv[5] || (__dirname + '/detect-out.json')).split('\\').join('/');

// Only what the detector needs. Bands and known rules are joined back by page key locally:
// every byte here is echoed into the transcript by the browser tool.
const slice = inv.slice(OFFSET, OFFSET + COUNT).map(p => ({
  k: p.dump_folder + '#' + p.pg,
  src: p.src,
  top: p.top_pct == null ? null : Number(p.top_pct),
  bot: p.bottom_pct == null ? null : Number(p.bottom_pct),
}));

const body = `async (page) => {
  const PAGES = ${JSON.stringify(slice)};
  // goto rather than setContent: setContent waits for "load" and has timed out on this MCP page
  // after a previous run left a download pending.
  await page.goto('about:blank', { waitUntil: 'domcontentloaded' });
  const out = await page.evaluate(async (PAGES) => {

    const FULL_RUN   = 0.80;   // at or above this the rule spans the whole form: a SLOT BOUNDARY
    const MIN_RUN    = 0.33;   // below this it is not a printed rule at all
    const MIN_SEP_PP = 0.70;   // two rules closer than this are one rule seen twice
    const SLOPES     = [-8,-6,-5,-4,-3,-2,-1,0,1,2,3,4,5,6,8].map(v => v / 1000);

    const load = src => new Promise((ok, no) => {
      const i = new Image(); i.crossOrigin = 'anonymous';
      i.onload = () => ok(i); i.onerror = () => no(new Error('load fail')); i.src = src;
    });

    const results = [];
    for (const P of PAGES) {
      const rec = { k: P.k, top: P.top, bot: P.bot };
      try {
        const img = await load(P.src);
        const W = img.naturalWidth, H = img.naturalHeight;
        const c = document.createElement('canvas'); c.width = W; c.height = H;
        const g = c.getContext('2d', { willReadFrequently: true });
        g.drawImage(img, 0, 0);
        const d = g.getImageData(0, 0, W, H).data;

        const L = new Uint8Array(W * H);
        for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
          const i = (y * W + x) * 4;
          L[y * W + x] = (0.299 * d[i] + 0.587 * d[i+1] + 0.114 * d[i+2]) | 0;
        }

        // The roster band. The extent when the page has one, else a generous default. Measuring
        // the paper level over the WHOLE page would drag in the dark form header at the top.
        const yA = Math.max(2, Math.round(((P.top != null ? P.top : 18) - 5) / 100 * H));
        const yB = Math.min(H - 3, Math.round(((P.bot != null ? P.bot : 72) + 5) / 100 * H));
        const x0 = Math.floor(W * 0.02), x1 = Math.floor(W * 0.92), span = x1 - x0;
        const xMid = (x0 + x1) / 2;

        rec.W = W; rec.H = H;
        {
          const s = [];
          for (let y = yA; y <= yB; y += 3) for (let x = x0; x < x1; x += 5) s.push(L[y * W + x]);
          s.sort((a, b) => a - b);
          rec.luma_p10 = s[(s.length * 0.10) | 0];
          rec.luma_med = s[(s.length * 0.50) | 0];
          rec.luma_p90 = s[(s.length * 0.90) | 0];
        }

        // Per-column paper level: the 70th percentile of that column's luma down the roster. A
        // column that happens to carry a vertical table line is still mostly paper, so a high
        // percentile finds the paper rather than the line.
        const paper = new Float32Array(W);
        const cut = new Float32Array(W);
        {
          const col = [];
          for (let x = x0; x < x1; x++) {
            col.length = 0;
            for (let y = yA; y <= yB; y += 2) col.push(L[y * W + x]);
            col.sort((a, b) => a - b);
            const p = col[(col.length * 0.70) | 0];
            paper[x] = p;
            cut[x] = p - Math.max(9, p * 0.10);
          }
        }

        // runFrac under a given shear. dy(x) = round(slope * (x - xMid)), so slope is rise over
        // run across the page: 0.004 is about 0.23 degrees, roughly 4px across a 1000px sheet.
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

        // Pick the shear that maximises full-width evidence. Score = number of rows reaching
        // FULL_RUN, tie-broken toward slope 0 so a page with no skew is left alone.
        let bestSlope = 0, bestScore = -1, zeroScore = 0;
        for (const s of SLOPES) {
          const rf = profileFor(s);
          let n = 0;
          for (let y = yA - 12; y <= yB + 12; y++) if (rf[y] >= FULL_RUN) n++;
          if (s === 0) zeroScore = n;
          if (n > bestScore || (n === bestScore && Math.abs(s) < Math.abs(bestSlope))) { bestScore = n; bestSlope = s; }
        }
        rec.skew = bestSlope;
        rec.skew_rows_at_zero = zeroScore;
        rec.skew_rows_best = bestScore;
        rec.skew_gain = bestScore - zeroScore;

        const rf = profileFor(bestSlope);

        // ink fraction at the chosen shear, recorded for continuity with the 2026-08-03 detector
        const inkAt = (y) => {
          let n = 0;
          for (let x = x0; x < x1; x++) {
            const yy = y + ((bestSlope * (x - xMid)) | 0);
            if (yy >= 0 && yy < H && L[yy * W + x] < cut[x]) n++;
          }
          return n / span;
        };

        // Non-maximum suppression. Greedily take the strongest remaining row, then forbid
        // everything within MIN_SEP. No thickness filter: v1 discarded thick groups and thereby
        // deleted exactly the strongest rules whenever their shoulders merged with nearby ink.
        const sep = Math.max(3, Math.round(H * MIN_SEP_PP / 100));
        const cand = [];
        for (let y = yA - 12; y <= yB + 12; y++) if (rf[y] >= MIN_RUN) cand.push(y);
        cand.sort((a, b) => rf[b] - rf[a]);
        const taken = [];
        for (const y of cand) {
          if (taken.some(t => Math.abs(t - y) < sep)) continue;
          taken.push(y);
        }

        const rules = taken.map(y => {
          // refine to the centroid of the plateau, which removes the upward bias the one-row
          // vertical tolerance gives to a plain argmax
          // ⚠ CAP THE PLATEAU. Unbounded expansion walks across a flat stretch of profile and
          // drags the centroid off the peak: it collapsed a boundary at run 0.997 and a divider at
          // 0.427 onto the same position on ticket-832487 p1, which is both a lost rule and a
          // primary-key collision. The cap is half the NMS separation, so a refined position can
          // never cross into a neighbouring peak's territory.
          const v = rf[y];
          const lim = Math.max(2, Math.round(H * MIN_SEP_PP / 200));
          let a = y, b = y;
          while (a > 1 && y - a < lim && rf[a - 1] >= v - 0.03) a--;
          while (b < H - 2 && b - y < lim && rf[b + 1] >= v - 0.03) b++;
          const mid = (a + b) / 2;
          return {
            pct: +(((mid + 0.5) / H) * 100).toFixed(3),
            run: +v.toFixed(3),
            ink: +inkAt(y).toFixed(3),
            kind: v >= FULL_RUN ? 'full' : 'part',
            thick: b - a + 1,
          };
        }).sort((p, q) => p.pct - q.pct);

        rec.rules = rules;
        const full = rules.filter(r => r.kind === 'full').map(r => r.pct);
        rec.n_full = full.length;
        rec.n_part = rules.length - full.length;

        // gaps between consecutive full-width rules, for the confidence gate: a MISSING rule shows
        // up as one gap that is a clean multiple of the others
        const gaps = [];
        for (let i = 1; i < full.length; i++) gaps.push(+(full[i] - full[i - 1]).toFixed(3));
        rec.gaps = gaps;
        const sorted = [...gaps].sort((a, b) => a - b);
        rec.pitch = sorted.length ? sorted[(sorted.length / 2) | 0] : null;
        rec.max_gap = gaps.length ? Math.max(...gaps) : null;
        rec.min_gap = gaps.length ? Math.min(...gaps) : null;
      } catch (e) { rec.error = String(e).slice(0, 90); }
      results.push(rec);
    }
    return results;
  }, PAGES);

  await page.goto('about:blank', { waitUntil: 'domcontentloaded' });
  await page.evaluate(() => {
    const a = document.createElement('a'); a.id = 'dl'; a.textContent = 'x';
    document.body.appendChild(a);
  });
  const payload = JSON.stringify(out);
  const [download] = await Promise.all([
    page.waitForEvent('download', { timeout: 120000 }),
    page.evaluate((txt) => {
      const a = document.getElementById('dl');
      a.href = URL.createObjectURL(new Blob([txt], { type: 'application/json' }));
      a.download = 'detect.json';
      a.click();
    }, payload),
  ]);
  await download.saveAs('${OUTFILE}');
  const bad = out.filter(r => r.error).map(r => r.k + ':' + r.error);
  return out.length + ' pages -> ${OUTFILE} (' + payload.length + ' bytes)'
    + (bad.length ? '  ERRORS: ' + bad.join(' | ') : '');
}`;

fs.writeFileSync(__dirname + '/detect-run.js', body);
console.log('wrote detect-run.js: pages ' + OFFSET + '..' + (OFFSET + slice.length - 1)
  + ' (' + slice.length + ')');
