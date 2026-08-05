// derm-tracker-write-path.js
// Proves, against the LIVE published bundle, that the DERM Tracker no longer writes
// public.visits.derm_required directly and instead calls the two manual RPCs.
//
// Why this file exists: a Lovable chat card saying "done" is a CLAIM (Building Apps rule #15),
// and the Publish panel can say "Up to date" while the live artifact lacks the change (rule #17).
// The live bytes are the only ground truth.
//
// Two traps this script is built around, both of which have produced confident false ZEROs here:
//   1. CHUNK DISCOVERY. The two write sites live on lazily-loaded ROUTE chunks. The root HTML
//      never references them, so a scan seeded only from index-*.js reports 0 and reads as
//      an all-clear. We walk /assets/*.js to closure AND seed from the real routes.
//   2. QUOTE DELIMITERS. A ["'] -only matcher is blind to a backtick-quoted bundle and returns a
//      confident zero (workspace CLAUDE.md 5c). We capture the delimiter and back-reference it.
//
// Every assertion below is paired with a positive control that MUST fire. A sweep that returns
// 0 without a firing control is an untested instrument, not a pass.
//
// Usage: node scripts/checks/derm-tracker-write-path.js [origin]

const ORIGIN = process.argv[2] || 'https://derm.unclogme.app';

// Seeded from the REAL routes, not just '/'. These are where the two write sites live.
const SEED_ROUTES = ['/', '/visits/6189', '/manifests'];

async function get(url) {
  const r = await fetch(url, { headers: { 'User-Agent': 'unclogme-bundle-check' } });
  if (!r.ok) return null;
  return await r.text();
}

async function discoverChunks() {
  const seen = new Set();
  const queue = [];

  for (const route of SEED_ROUTES) {
    const html = await get(ORIGIN + route);
    if (!html) continue;
    for (const m of html.matchAll(/["'(]([^"'()\s]*\/assets\/[^"'()\s]+\.js)["')]/g)) {
      queue.push(new URL(m[1], ORIGIN).href);
    }
  }

  const bodies = new Map();
  while (queue.length) {
    const url = queue.shift();
    if (seen.has(url)) continue;
    seen.add(url);
    const body = await get(url);
    if (!body) continue;
    bodies.set(url, body);
    // walk to closure: chunks import other chunks by relative path
    for (const m of body.matchAll(/["'(]([^"'()\s]*\/assets\/[^"'()\s]+\.js)["')]/g)) {
      const next = new URL(m[1], ORIGIN).href;
      if (!seen.has(next)) queue.push(next);
    }
  }
  return bodies;
}

// Delimiter-agnostic: capture the quote and back-reference it, so `x` matches but "x` does not.
const rpcCalls = (s) => [...s.matchAll(/\.rpc\(\s*(["'`])([A-Za-z0-9_]+)\1/g)].map((m) => m[2]);
const fromTables = (s) => [...s.matchAll(/\.from\(\s*(["'`])([A-Za-z0-9_.]+)\1/g)].map((m) => m[2]);

(async () => {
  const bodies = await discoverChunks();
  const all = [...bodies.values()].join('\n');
  const totalBytes = all.length;

  const rpcs = new Set(rpcCalls(all));
  const tables = new Set(fromTables(all));

  // ---- POSITIVE CONTROLS (must all fire, else the instrument is broken) ----
  const controls = {
    chunks_found: bodies.size,
    bytes_found: totalBytes,
    supabase_client_present: /supabase/i.test(all),
    string_literals_seen: (all.match(/(["'`])[A-Za-z0-9_ .:\-]{4,}\1/g) || []).length,
    rpc_names_seen: rpcs.size,
    table_names_seen: tables.size,
    mentions_derm_required: all.includes('derm_required'),
  };
  const controlFailures = [];
  if (controls.chunks_found < 2) controlFailures.push('fewer than 2 chunks discovered - the walk did not run');
  if (controls.bytes_found < 100000) controlFailures.push('bundle under 100KB - almost certainly a partial walk');
  if (!controls.supabase_client_present) controlFailures.push('no supabase reference - wrong app or wrong bytes');
  if (controls.string_literals_seen < 100) controlFailures.push('under 100 string literals - the literal matcher is blind to this quoting style');
  if (controls.rpc_names_seen === 0) controlFailures.push('zero .rpc() names extracted - the extractor is broken');
  if (!controls.mentions_derm_required) controlFailures.push('derm_required absent entirely - not the DERM Tracker bundle');

  // ---- THE ACTUAL ASSERTIONS ----
  const findings = {
    // must be PRESENT
    bulk_rpc_present: rpcs.has('set_visits_derm_required_manual'),
    single_rpc_present: rpcs.has('set_visit_derm_required_manual'),
    // must be ABSENT: the direct table write, in either quoting style
    direct_visits_update: [...all.matchAll(/\.from\(\s*(["'`])visits\1\s*\)\s*\.update\(/g)].length,
    // must be ABSENT: the BULK manifest_visits delete that the RPC now folds in.
    // ⚠ Scope this to the BULK shape (.in("visit_id", array)) and NOT to every
    // manifest_visits delete. A bare "any delete" assertion is TOO BROAD and produced a
    // false FAIL on the first run: three legitimate, unrelated single-link detach features
    // (detail-page unlink, move-to-manifest cleanup, "Visit removed from manifest") each do a
    // scoped .eq("manifest_id",..).eq("visit_id",..) delete and must survive. Over-broad
    // assertions are the mirror image of the false-zero problem - both end in a wrong verdict.
    manifest_visits_bulk_delete: [...all.matchAll(/\.from\(\s*(["'`])manifest_visits\1\s*\)\s*\.delete\([^;]{0,120}?\.in\(/g)].length,
    // Tripwire, informational: the count of scoped single-pair detaches. Expected 3 as of
    // 2026-08-05. If this MOVES, a detach feature was added or removed - go look, do not
    // just update the number.
    manifest_visits_scoped_delete: [...all.matchAll(/\.from\(\s*(["'`])manifest_visits\1\s*\)\s*\.delete\(/g)].length,
    // informational
    derm_required_in_update_literal: [...all.matchAll(/update\(\s*\{[^}]{0,80}derm_required/g)].length,
    all_rpcs: [...rpcs].sort(),
  };

  const failures = [];
  if (controlFailures.length) failures.push(...controlFailures.map((c) => 'CONTROL: ' + c));
  if (!findings.bulk_rpc_present) failures.push('set_visits_derm_required_manual NOT in the live bundle');
  if (!findings.single_rpc_present) failures.push('set_visit_derm_required_manual NOT in the live bundle');
  if (findings.direct_visits_update > 0) failures.push(`${findings.direct_visits_update} direct .from("visits").update( call(s) remain`);
  if (findings.manifest_visits_bulk_delete > 0) failures.push(`${findings.manifest_visits_bulk_delete} BULK manifest_visits delete(s) remain - the RPC should own this`);
  if (findings.manifest_visits_scoped_delete !== 3) failures.push(`scoped manifest_visits detaches moved 3 -> ${findings.manifest_visits_scoped_delete}; a detach feature changed, go look`);
  if (findings.derm_required_in_update_literal > 0) failures.push(`${findings.derm_required_in_update_literal} update({...derm_required...}) literal(s) remain`);

  console.log(JSON.stringify({ origin: ORIGIN, controls, findings, failures, verdict: failures.length ? 'FAIL' : 'PASS' }, null, 2));
  console.log('--- audit complete --- ' + JSON.stringify({ probe: 'derm_tracker_write_path', chunks: bodies.size, failures: failures.length }));
  process.exit(failures.length ? 1 : 0);
})();
