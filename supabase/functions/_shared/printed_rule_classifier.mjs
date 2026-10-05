// printed_rule_classifier.mjs: the labelling pass of the printed-rule detector (which detected line is a
// slot boundary, a mid-slot divider or the form's header/footer bar, and the page grade), as ONE module
// imported by the edge function measure-page-reference.
//
// EXTRACTED 2026-10-05 BY SCRIPT, NOT RETYPED, from Building Apps/DERM Stamp Studio/docs/
// printed-rule-detector.reference.js (classifyPage and the four constants it reads, byte for byte).
// That file is the canonical copy of what the Stamp Studio ran in the browser until its Re-measure
// was removed (2026-10-05); the pixel pass it pairs with is ./printed_rule_detector.mjs (detectRules).
// Fred, 2026-10-05: "yes measure in the background". Do not tune the numbers here: see the header of
// the reference file. Check: node scripts/checks/page_reference_classifier.mjs (real scans whose
// in-app measurement is on record).

const MIN_SEP_PP = 0.70;
const MIN_PHASE_EDGE = 0.04;
const GAP_TOL = 0.30;
const MIN_RULES = 5;

export function classifyPage(rec) {
  const r = { W: rec.W, H: rec.H, skew: rec.skew, skew_saturated: rec.skew_saturated, luma_med: rec.luma_med };
  if (rec.error) { r.grade = 'FAILED'; r.detail = 'image: ' + rec.error; r.rules = []; return r; }

  // 🛑 WHEN THERE IS NO EXTENT, TRIM TO THE DETECTOR'S OWN ASSUMED ROSTER, NOT TO INFINITY.
  // classify.js used +/-1e9 here, and that is safe only because 166 of the 168 measured pages have
  // a page extent to trim by. The six pages that are BLOCKED have none, and with an infinite window
  // the form's header and footer bars stay in the chain: on ticket-312433 p1 two full-width footer
  // bars at 65.864 and 68.244 landed in divider slots, the run-length split disagreed with the
  // labels at chain position 14 (run 0.988 labelled divider), and the whole page was refused.
  // The detector already assumes the roster is 18..72 when no extent is given (see yA/yB above), so
  // the two halves were simply inconsistent. Measured fleet extents span 20.4 to 68.2, so this
  // window contains every real roster with margin.
  const lo = rec.top != null ? rec.top - 2.0 : 16.0;
  const hi = rec.bot != null ? rec.bot + 2.0 : 74.0;

  // Merge near-duplicates FIRST, or the alternation is corrupted.
  const allRaw = rec.rules.slice().sort((a, b) => a.pct - b.pct);
  const all = [];
  for (const x of allRaw) {
    const prev = all[all.length - 1];
    if (prev && x.pct - prev.pct < MIN_SEP_PP) {
      if (x.run > prev.run) all[all.length - 1] = x;
      continue;
    }
    all.push(x);
  }
  const rules = all.filter(x => x.pct >= lo && x.pct <= hi);

  // Remove the form's header and footer bars BY SHAPE, not by position. Two lists on purpose:
  // `rules` is every printed rule (a header bar IS a printed rule and an edge on it is genuinely
  // not inside text); `chain` is the roster's alternating sequence, which the bars would break.
  let chain = rules.slice();
  {
    const spacings = [];
    for (let i = 1; i < rules.length; i++) spacings.push(rules[i].pct - rules[i - 1].pct);
    spacings.sort((a, b) => a - b);
    const halfPitch = spacings.length ? spacings[(spacings.length / 2) | 0] : 0;
    // "LONG" must come from the page's own cluster split, never a fraction of its maximum: on
    // ticket-311045 p1 the clusters sit at 0.403 and 0.542 and a fixed fraction marks every rule long.
    const runsSorted = rules.map(x => x.run).slice().sort((a, b) => a - b);
    let cutRun = null, cutGapRun = 0;
    for (let i = 1; i < runsSorted.length; i++) {
      const gp = runsSorted[i] - runsSorted[i - 1];
      if (gp > cutGapRun) { cutGapRun = gp; cutRun = (runsSorted[i] + runsSorted[i - 1]) / 2; }
    }
    const isLong = x => cutRun != null && x.run >= cutRun;
    const close = (a, b) => Math.abs(b.pct - a.pct) < 0.6 * 2 * halfPitch;
    let guard = 0;
    while (chain.length > 6 && guard++ < 2
      && isLong(chain[0]) && isLong(chain[1]) && close(chain[0], chain[1])) chain = chain.slice(1);
    guard = 0;
    while (chain.length > 6 && guard++ < 2
      && isLong(chain[chain.length - 1]) && isLong(chain[chain.length - 2])
      && close(chain[chain.length - 2], chain[chain.length - 1])) chain = chain.slice(0, -1);
  }

  const unclassified = () => rules.map(x => ({ pct: x.pct, run: x.run, ink: x.ink, kind: 'unclassified' }));

  if (chain.length < MIN_RULES) {
    r.grade = 'FAILED';
    r.detail = 'only ' + chain.length + ' rules inside the roster';
    r.rules = unclassified();
    return r;
  }

  const mean = a => a.reduce((s, x) => s + x, 0) / a.length;
  const phase = (p) => chain.filter((_, i) => i % 2 === p);
  const scoreOf = (p) => {
    const A = phase(p).map(x => x.run), B = phase(1 - p).map(x => x.run);
    return (A.length && B.length) ? mean(A) - mean(B) : -1;
  };
  const s0 = scoreOf(0), s1 = scoreOf(1);
  const best = s0 >= s1 ? 0 : 1;
  r.phase_edge = +Math.max(s0, s1).toFixed(3);

  if (r.phase_edge < MIN_PHASE_EDGE) {
    r.grade = 'FAILED';
    r.detail = 'the two phases are indistinguishable (edge ' + r.phase_edge
      + '): cannot tell a slot boundary from a mid-slot divider';
    r.rules = unclassified();
    return r;
  }

  const bounds = phase(best);
  const bset = new Set(bounds);
  r.rules = rules.map(x => ({
    pct: x.pct, run: x.run, ink: x.ink,
    kind: bset.has(x) ? 'boundary' : (chain.includes(x) ? 'divider' : 'header-footer'),
  }));

  const gaps = [];
  for (let i = 1; i < bounds.length; i++) gaps.push(+(bounds[i].pct - bounds[i - 1].pct).toFixed(3));
  const sortedGaps = [...gaps].sort((a, b) => a - b);
  r.pitch = sortedGaps.length ? +sortedGaps[(sortedGaps.length / 2) | 0].toFixed(3) : null;
  r.n_boundaries = bounds.length;

  if (bounds.length < 3) {
    r.grade = 'FAILED';
    r.detail = 'only ' + bounds.length + ' slot boundaries';
    r.rules = unclassified();
    return r;
  }

  const big = gaps.filter(g => g > r.pitch * (1 + GAP_TOL));
  const off = gaps.filter(g => Math.abs(g - r.pitch) > GAP_TOL * r.pitch);
  if (big.length) { r.grade = 'SPARSE'; r.detail = big.length + ' gap(s) above the pitch ' + r.pitch + ': ' + big.join(', '); }
  else if (off.length) { r.grade = 'IRREGULAR'; r.detail = off.length + ' gap(s) off the pitch ' + r.pitch + ': ' + off.join(', '); }
  else { r.grade = 'OK'; r.detail = bounds.length + ' boundaries, pitch ' + r.pitch; }
  return r;
}
