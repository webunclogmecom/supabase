// CLASSIFY the detected rules on each page into SLOT BOUNDARIES vs MID-SLOT DIVIDERS, and grade
// how far that page's geometry can be trusted.
//
// ============================================================================================
// THE STRUCTURE THIS RELIES ON
// ============================================================================================
// Down the roster the printed rules STRICTLY ALTERNATE:
//
//     ---------- slot boundary          (spans the whole form)
//        Facility Name        row
//     - - - - -  mid-slot divider       (stops at the first vertical column line)
//        Complete Facility Address  row
//     ---------- slot boundary
//
// Verified on every page where the run lengths separate cleanly. derm/1194 p3, for instance:
//     25.779 B   29.870 .   34.156 B   37.532 .   40.909 B   44.156 .   48.182 B ...
//
// So the classification is a PHASE choice over the sorted rule list, not a threshold. Take the
// even-indexed rules or the odd-indexed ones, whichever set has the longer runs on average.
//
// 🛑 WHY NOT A RUN THRESHOLD, WHICH IS THE OBVIOUS THING. The fleet histogram is beautifully
// bimodal at ~0.41 and ~1.00, and a fixed 0.80 cut still gets four kinds of page wrong:
//   ticket-310607 p1   clusters at 0.37 and 0.56; NOTHING reaches 0.80, so the page reports zero
//                      slot boundaries and looks undetectable
//   ticket-832996 p1   five boundaries at 1.00 and a sixth at 0.72 where the sheet is cropped
//   ticket-831938 p2   four at 0.99 and two at 0.51, so the page reports gaps of 15.17 and 15.80
//   derm/1236 p1       all fourteen rules at 0.35, evenly spaced: no split exists at any threshold
// The phase choice handles all four, because it asks which SET is longer rather than how long any
// individual rule is. The threshold split is still computed and kept as a cross-check.
//
// 🛑 AND TRIM TO THE ROSTER BEFORE ANY OF THIS. The form's header band ("B: Origination of
// Waste") and its footer ("Attach Additional Sheets...") are full-width dark bars that detect as
// perfect rules and are not slot boundaries. Left in, they put a ~2.0pp and a ~2.4pp gap into a
// 5.4pp pitch and graded 81 of 160 pages IRREGULAR. The page extent is the measured span of the
// printed roster, which is exactly the right trim.
//
// Grades, and none of them is silence:
//   OK          boundaries alternate cleanly and the spacing fits one pitch
//   IRREGULAR   boundaries found, spacing does not fit one pitch: the page needs eyes
//   SPARSE      a gap looks like a whole missing boundary
//   FAILED      too few rules, or the two phases are indistinguishable
//
// Usage: node classify.js <detect-out.json> <inventory.json> [--json out.json]
const fs = require('fs');
const det = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const inv = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const outIdx = process.argv.indexOf('--json');

const MIN_RULES      = 5;     // fewer than this in-roster and there is nothing to phase
const MIN_PHASE_EDGE = 0.04;  // the winning phase must be this much longer on average
const GAP_TOL        = 0.30;  // a gap may differ from the pitch by this fraction and still be OK

const byKey = {};
for (const p of inv) byKey[p.dump_folder + '#' + p.pg] = p;

const out = [];
for (const rec of det) {
  const meta = byKey[rec.k] || {};
  const r = {
    k: rec.k, dump_folder: meta.dump_folder, pg: meta.pg,
    W: rec.W, H: rec.H, src: meta.src, skew: rec.skew, skew_gain: rec.skew_gain, luma_med: rec.luma_med,
    top: rec.top, bot: rec.bot, known: meta.known || [], bands: meta.rows || [],
  };
  if (rec.error) { r.grade = 'FAILED'; r.why = 'image: ' + rec.error; out.push(r); continue; }

  const lo = rec.top != null ? rec.top - 1.0 : -1e9;
  const hi = rec.bot != null ? rec.bot + 1.0 : 1e9;
  const all = rec.rules.slice().sort((a, b) => a.pct - b.pct);
  const rules = all.filter(x => x.pct >= lo && x.pct <= hi);
  r.n_trimmed = all.length - rules.length;
  r.no_extent = rec.top == null || rec.bot == null;
  r.n_rules = rules.length;

  if (rules.length < MIN_RULES) {
    r.grade = 'FAILED'; r.why = 'only ' + rules.length + ' rules inside the roster';
    r.rules = rules.map(x => ({ pct: x.pct, run: x.run, ink: x.ink, b: false }));
    out.push(r); continue;
  }

  // ---- phase choice ------------------------------------------------------------------------
  const mean = a => a.reduce((s, x) => s + x, 0) / a.length;
  const phase = (p) => rules.filter((_, i) => i % 2 === p);
  const scoreOf = (p) => {
    const A = phase(p).map(x => x.run), B = phase(1 - p).map(x => x.run);
    return (A.length && B.length) ? mean(A) - mean(B) : -1;
  };
  const s0 = scoreOf(0), s1 = scoreOf(1);
  const best = s0 >= s1 ? 0 : 1;
  r.phase = best;
  r.phase_edge = +Math.max(s0, s1).toFixed(3);

  if (r.phase_edge < MIN_PHASE_EDGE) {
    r.grade = 'FAILED';
    r.why = 'the two phases are indistinguishable (edge ' + r.phase_edge + '): cannot tell a slot '
      + 'boundary from a mid-slot divider';
    r.rules = rules.map(x => ({ pct: x.pct, run: x.run, ink: x.ink, b: false }));
    out.push(r); continue;
  }

  const bounds = phase(best);
  r.bounds = bounds.map(x => x.pct);
  r.n_bounds = bounds.length;
  r.rules = rules.map((x, i) => ({ pct: x.pct, run: x.run, ink: x.ink, b: i % 2 === best }));

  // cross-check: does a plain run-length split agree with the phase choice? Recorded rather than
  // enforced. Disagreement is a signal that this page is unusual, not that either is wrong.
  {
    const runs = rules.map(x => x.run).slice().sort((a, b) => a - b);
    let cutAt = null, cutGap = 0;
    for (let i = 1; i < runs.length; i++) {
      const g = runs[i] - runs[i - 1];
      if (g > cutGap) { cutGap = g; cutAt = (runs[i] + runs[i - 1]) / 2; }
    }
    r.split_cut = cutAt == null ? null : +cutAt.toFixed(3);
    r.split_agrees = cutAt == null ? null
      : rules.every((x, i) => (x.run >= cutAt) === (i % 2 === best));
  }

  const gaps = [];
  for (let i = 1; i < bounds.length; i++) gaps.push(+(bounds[i].pct - bounds[i - 1].pct).toFixed(3));
  r.gaps = gaps;
  const sortedGaps = [...gaps].sort((a, b) => a - b);
  r.pitch = sortedGaps.length ? +sortedGaps[(sortedGaps.length / 2) | 0].toFixed(3) : null;

  if (bounds.length < 3) { r.grade = 'FAILED'; r.why = 'only ' + bounds.length + ' slot boundaries'; }
  else {
    const big = gaps.filter(g => g > r.pitch * (1 + GAP_TOL));
    const off = gaps.filter(g => Math.abs(g - r.pitch) > GAP_TOL * r.pitch);
    if (big.length) { r.grade = 'SPARSE'; r.why = big.length + ' gap(s) above the pitch ' + r.pitch + ': ' + big.join(', '); }
    else if (off.length) { r.grade = 'IRREGULAR'; r.why = off.length + ' gap(s) off the pitch ' + r.pitch + ': ' + off.join(', '); }
    else { r.grade = 'OK'; r.why = bounds.length + ' boundaries, pitch ' + r.pitch; }
  }
  out.push(r);
}

if (outIdx > 0) fs.writeFileSync(process.argv[outIdx + 1], JSON.stringify(out));

// ---- report --------------------------------------------------------------------------------
const g = {}; out.forEach(r => g[r.grade] = (g[r.grade] || 0) + 1);
console.log('GRADES over ' + out.length + ' pages: ' + Object.entries(g).map(([k, v]) => k + ' ' + v).join('   '));

// REGRESSION. Reported two ways on purpose: the raw number, and the number restricted to rules
// inside the roster. The trim deliberately drops header/footer bars that the 2026-08-03 detector
// recorded, so the raw number understates recall, and quietly reporting only the flattering one
// is how a regression gets hidden.
let hit = 0, miss = 0, outside = 0, dsum = 0, dmax = 0; const missBy = {};
for (const r of out) {
  const lo = (r.top == null ? -1e9 : r.top - 1.0), hi = (r.bot == null ? 1e9 : r.bot + 1.0);
  for (const k of r.known) {
    if (k < lo || k > hi) { outside++; continue; }
    let b = 1e9;
    for (const x of (r.rules || [])) { const d = Math.abs(x.pct - k); if (d < b) b = d; }
    if (b <= 0.30) { hit++; dsum += b; dmax = Math.max(dmax, b); }
    else { miss++; (missBy[r.k] = missBy[r.k] || []).push(k + '(~' + b.toFixed(2) + ')'); }
  }
}
console.log('REGRESSION vs hand-recorded rules INSIDE the roster: hit ' + hit + '  miss ' + miss
  + '  recall ' + (100 * hit / (hit + miss)).toFixed(1) + '%  meanDist ' + (dsum / hit).toFixed(3)
  + '  maxDist ' + dmax.toFixed(3));
console.log('  (' + outside + ' further hand-recorded rules sit outside the roster: header and '
  + 'footer bars, deliberately not counted)');
for (const [k, v] of Object.entries(missBy)) console.log('   MISS ' + k.padEnd(22) + v.join(', '));

const dis = out.filter(r => r.split_agrees === false);
console.log();
console.log('CROSS-CHECK: the run-length split disagrees with the alternation on ' + dis.length + ' of '
  + out.filter(r => r.split_agrees != null).length + ' pages');

console.log();
console.log('NOT OK:');
for (const r of out.filter(x => x.grade !== 'OK')) {
  console.log('  ' + r.grade.padEnd(10) + r.k.padEnd(22) + 'rules ' + String(r.n_rules).padStart(3)
    + '  bounds ' + String(r.n_bounds == null ? '-' : r.n_bounds).padStart(2)
    + '  edge ' + String(r.phase_edge == null ? '-' : r.phase_edge).padStart(5)
    + '  luma ' + String(r.luma_med).padStart(4) + '   ' + r.why);
}
