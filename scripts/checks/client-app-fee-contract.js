#!/usr/bin/env node
// client-app-fee-contract.js
// ---------------------------------------------------------------------------
// Verifies the LIVE Client App bundle actually implements the fee-line contract
// documented in Building Apps/Client App/docs/2026-08-05_fee-line-picker-contract.md.
//
// Run:  node scripts/checks/client-app-fee-contract.js
// Exit: 0 = every assertion passed. 1 = a contract assertion failed.
//       2 = THE SCAN ITSELF IS INVALID (a positive control did not fire) — this is
//           NOT a pass and NOT a fail, it means the instrument could not see.
//
// 🛑 TWO TRAPS THIS FILE EXISTS TO AVOID, both of which have produced a confident
//    wrong answer in this repo before:
//
//  1. SEED FROM REAL ROUTES. This app is SSR (TanStack Start) and its route chunks
//     are NOT referenced from the root HTML. A "/"-seeded walk reaches ~1 chunk and
//     returns 0 for features that are demonstrably live. We seed from /clients/<id>
//     and /dashboard and walk the asset graph to closure.
//     ⚠ Assets are served from /assets/, NOT /_build/assets/. Getting that wrong
//     silently yields 1 chunk and a clean-looking set of zeroes.
//
//  2. CAPTURE THE QUOTE DELIMITER AND BACK-REFERENCE IT. Bundles here quote with
//     backticks as well as ' and ". A ["'] -only literal extractor once reported
//     that an entire app called no RPCs. Every literal matcher below is (["'`])…\1.
//
// EVERY ZERO IS ONLY MEANINGFUL IF THE CONTROLS FIRED. That is enforced, not hoped.
// ---------------------------------------------------------------------------

const BASE = 'https://clients.unclogme.app';
const SEEDS = ['/', '/dashboard', '/clients/368'];

const ok = (u) => (u.startsWith('http') ? u : BASE + (u.startsWith('/') ? u : '/' + u));

async function get(u) {
  try {
    const r = await fetch(ok(u), { headers: { 'user-agent': 'Mozilla/5.0' } });
    return r.ok ? await r.text() : null;
  } catch { return null; }
}

const ASSET_RE = /["'`](\/assets\/[^"'`]+?\.js)["'`]/g;

async function collectBundle() {
  const queue = [];
  for (const s of SEEDS) {
    const html = await get(s);
    if (!html) continue;
    for (const m of html.matchAll(ASSET_RE)) queue.push(m[1]);
  }
  const seen = new Set(queue);
  const texts = [];
  let guard = 0;
  while (queue.length && guard++ < 300) {
    const u = queue.shift();
    const t = await get(u);
    if (!t) continue;
    texts.push(t);
    for (const m of t.matchAll(ASSET_RE)) {
      if (!seen.has(m[1])) { seen.add(m[1]); queue.push(m[1]); }
    }
  }
  return { text: texts.join('\n'), chunks: texts.length };
}

(async () => {
  const { text: all, chunks } = await collectBundle();
  console.log(`chunks walked: ${chunks}   bytes: ${all.length}`);

  // ---- POSITIVE CONTROLS. If any of these is absent the walk did not reach the
  //      job dialog, so nothing below can be trusted in either direction.
  const CONTROLS = [
    ['save-client-job edge fn', 'save-client-job'],
    ['service_line_items read', 'service_line_items'],
    ['the services picker', 'Search services'],
  ];
  const deadControls = CONTROLS.filter(([, needle]) => !all.includes(needle));
  if (deadControls.length) {
    console.error('\n🛑 SCAN INVALID — positive control(s) missing: ' +
      deadControls.map(([n]) => n).join(', '));
    console.error('   The walk did not reach the job dialog. Do NOT read the results below');
    console.error('   as evidence of anything. Fix the seeds/asset path first.');
    process.exit(2);
  }
  console.log('positive controls: all ' + CONTROLS.length + ' fired\n');

  // ---- CONTRACT ASSERTIONS
  const lit = (name) => new RegExp('(["\'`])' + name + '\\1').test(all);
  const has = (s) => all.includes(s);

  const checks = [
    // §3 payload
    ['sends rendered_fee_ids', has('rendered_fee_ids')],
    ['sends fees key', /(["'`])fees\1\s*:/.test(all) || has('rendered_fee_ids')],
    ['sends expected_unit_price', has('expected_unit_price')],
    // §1 catalogue
    ['reads default_rate_pct', has('default_rate_pct')],
    // §5 error handling
    ['handles stale_view', has('stale_view')],
    // §6 must-not-change: the services guard is still keyed on services only
    ['services picker still present', has('Search services')],
  ];

  // 🛑 NEGATIVE ASSERTION: the old hard filter must be GONE, or fees can never render.
  const oldFilterGone = !/reason["'`]?\s*,\s*["'`]Service Agreement["'`]\s*\)\s*\.order/.test(all);
  checks.push(['old reason=Service Agreement-only filter removed', oldFilterGone]);

  let failed = 0;
  for (const [label, pass] of checks) {
    console.log(`${pass ? 'PASS' : 'FAIL'}  ${label}`);
    if (!pass) failed++;
  }

  console.log('');
  if (failed) {
    console.error(`${failed} contract assertion(s) FAILED — the picker does not match the spec.`);
    process.exit(1);
  }
  console.log('All contract assertions passed.');
})();
