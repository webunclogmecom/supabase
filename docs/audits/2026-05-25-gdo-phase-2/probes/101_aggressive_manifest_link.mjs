// 101_aggressive_manifest_link.mjs
// Catch manifest_visits gaps the conservative backfill misses (Claudie case):
// AT visit "Visit Date" drifts up to 5+ days from the real DB visit_date,
// so the ±1 day window misses obvious matches.
//
// New strategy:
//   For each DB derm_manifest (client_id + white_manifest_number + service_date):
//     Find DB completed GT visits for the SAME client_id where:
//       - visit_date is within ±15 days of manifest.service_date
//       - no existing manifest_visits row for that visit
//     If exactly ONE such visit exists → that's the match. Link.
//     If multiple → skip (ambiguous, needs human).
//
// Re-runnable. Insert-only. Audit trigger fires automatically.
// Pass --execute to insert; default is dry-run.

import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
const EXECUTE = process.argv.includes('--execute');

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${(await r.text()).slice(0, 600)}`);
  return JSON.parse(await r.text());
}
const banner = (s) => console.log(`\n${'='.repeat(70)}\n${s}\n${'='.repeat(70)}`);
console.log(`Mode: ${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}`);

banner('Finding manifests with no link + a single nearby GT completion');
// Window: ±15 days of manifest.service_date. Only GT service_type, only completed.
const candidates = await pg(`
  WITH unlinked_manifests AS (
    SELECT dm.id AS manifest_id, dm.client_id, dm.service_date,
           dm.white_manifest_number
    FROM public.derm_manifests dm
    WHERE NOT EXISTS (
      SELECT 1 FROM public.manifest_visits mv WHERE mv.manifest_id = dm.id
    )
    AND dm.client_id IS NOT NULL
    AND dm.service_date IS NOT NULL
  ),
  visit_candidates AS (
    SELECT um.manifest_id, um.client_id, um.service_date AS m_date,
           um.white_manifest_number,
           v.id AS visit_id, v.visit_date,
           ABS((v.visit_date - um.service_date)) AS day_gap
    FROM unlinked_manifests um
    JOIN public.visits v
      ON v.client_id = um.client_id
     AND v.service_type = 'GT'
     AND v.visit_status = 'completed'
     AND v.visit_date BETWEEN um.service_date - INTERVAL '15 days'
                          AND um.service_date + INTERVAL '15 days'
    WHERE NOT EXISTS (
      SELECT 1 FROM public.manifest_visits mv2 WHERE mv2.visit_id = v.id
    )
  ),
  agg AS (
    SELECT manifest_id, client_id, m_date, white_manifest_number,
           COUNT(*)::int AS n_candidates,
           array_agg(json_build_object('vid', visit_id, 'vdate', visit_date, 'gap', day_gap) ORDER BY day_gap) AS candidates
    FROM visit_candidates
    GROUP BY manifest_id, client_id, m_date, white_manifest_number
  )
  SELECT *
  FROM agg
  ORDER BY n_candidates, m_date DESC
  LIMIT 500;
`);
const single = candidates.filter(c => c.n_candidates === 1);
const multi = candidates.filter(c => c.n_candidates > 1);

console.log(`Total unlinked manifests with at least one nearby GT visit: ${candidates.length}`);
console.log(`  -> exactly one (safe to link): ${single.length}`);
console.log(`  -> ambiguous (multiple candidates): ${multi.length}`);

banner('First 20 safe matches');
single.slice(0, 20).forEach(c => {
  const cand = c.candidates[0];
  console.log(`  manifest_id=${c.manifest_id}  #${c.white_manifest_number}  m_date=${c.m_date}  client=${c.client_id}  -> visit ${cand.vid} (vdate=${cand.vdate}, gap=${cand.gap}d)`);
});

if (multi.length > 0) {
  banner('Ambiguous cases (skipped, listing first 10)');
  multi.slice(0, 10).forEach(c => {
    console.log(`  manifest_id=${c.manifest_id}  #${c.white_manifest_number}  m_date=${c.m_date}  client=${c.client_id}  cands=${JSON.stringify(c.candidates)}`);
  });
}

if (!EXECUTE) {
  banner('Dry run. Re-run with --execute to insert.');
} else {
  banner('Inserting links for safe matches');
  let ok = 0, fail = 0;
  for (const c of single) {
    const visitId = c.candidates[0].vid;
    try {
      await pg(`
        INSERT INTO public.manifest_visits (visit_id, manifest_id)
        VALUES (${visitId}, ${c.manifest_id})
        ON CONFLICT (visit_id, manifest_id) DO NOTHING;
      `);
      ok++;
    } catch (e) {
      fail++;
      console.log(`  FAIL visit=${visitId} manifest=${c.manifest_id}: ${e.message}`);
    }
  }
  console.log(`Inserted: ${ok}, failed: ${fail}`);
}
