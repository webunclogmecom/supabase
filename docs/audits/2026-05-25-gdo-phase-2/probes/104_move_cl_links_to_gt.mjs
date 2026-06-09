// 104_move_cl_links_to_gt.mjs
// Move manifest_visits links incorrectly attached to CL visits onto the
// correct GT visit for the same client + nearby date. CL = Clear Line (drain
// cleaning) doesn't dump grease, so the DERM webhook never should have
// matched it. LS (Lift Station) is kept untouched — Bayshore's LS service
// may legitimately carry DERM links per ops choice.
//
// Strategy:
//   For each manifest_visits row where visits.service_type='CL':
//     find a GT visit for same client_id, status='completed', visit_date
//     within ±15 days of manifest.service_date, not already linked.
//   If exactly ONE GT candidate → swap.
//   If multiple → flag for Fred review.

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

banner('Find CL-attached DERM links with a clear GT alternative');
const proposals = await pg(`
  WITH wrong AS (
    SELECT mv.visit_id AS wrong_visit_id, mv.manifest_id,
           v.client_id, dm.service_date AS m_date,
           dm.white_manifest_number,
           c.client_code, c.name AS client_name,
           v.visit_date AS wrong_visit_date, v.title AS wrong_title
    FROM public.manifest_visits mv
    JOIN public.visits v ON v.id = mv.visit_id
    JOIN public.derm_manifests dm ON dm.id = mv.manifest_id
    JOIN public.clients c ON c.id = v.client_id
    WHERE v.service_type = 'CL'
  ),
  candidates AS (
    SELECT w.*, v2.id AS gt_visit_id, v2.visit_date AS gt_visit_date,
           ABS(v2.visit_date - w.m_date) AS gap_days
    FROM wrong w
    JOIN public.visits v2
      ON v2.client_id = w.client_id
     AND v2.service_type = 'GT'
     AND v2.visit_status = 'completed'
     AND v2.visit_date BETWEEN w.m_date - INTERVAL '15 days' AND w.m_date + INTERVAL '15 days'
    WHERE NOT EXISTS (
      SELECT 1 FROM public.manifest_visits mv2
      WHERE mv2.visit_id = v2.id AND mv2.manifest_id = w.manifest_id
    )
  ),
  agg AS (
    SELECT wrong_visit_id, manifest_id, client_code, client_name,
           white_manifest_number, m_date, wrong_visit_date, wrong_title,
           COUNT(*)::int AS n_gt_candidates,
           (array_agg(gt_visit_id ORDER BY gap_days))[1] AS best_gt_visit_id,
           (array_agg(gt_visit_date ORDER BY gap_days))[1] AS best_gt_date,
           (array_agg(gap_days ORDER BY gap_days))[1] AS best_gap
    FROM candidates
    GROUP BY wrong_visit_id, manifest_id, client_code, client_name,
             white_manifest_number, m_date, wrong_visit_date, wrong_title
  )
  SELECT * FROM agg ORDER BY n_gt_candidates, m_date DESC;
`);

const safe = proposals.filter(p => p.n_gt_candidates === 1);
const ambiguous = proposals.filter(p => p.n_gt_candidates > 1);

banner(`Safe single-candidate proposals (${safe.length})`);
safe.forEach(p => {
  console.log(`  #${(p.white_manifest_number || '—').padEnd(8)}  ${p.client_code.padEnd(10)} ${p.client_name.slice(0,30).padEnd(30)}`);
  console.log(`    REMOVE link  manifest=${p.manifest_id}  visit=${p.wrong_visit_id} (CL, ${p.wrong_visit_date})`);
  console.log(`    ADD link     manifest=${p.manifest_id}  visit=${p.best_gt_visit_id} (GT, ${p.best_gt_date}, gap=${p.best_gap}d)`);
});

if (ambiguous.length > 0) {
  banner(`Ambiguous — needs review (${ambiguous.length})`);
  ambiguous.forEach(p => {
    console.log(`  #${p.white_manifest_number}  ${p.client_code}  ${p.client_name}  →  ${p.n_gt_candidates} GT candidates near ${p.m_date}`);
  });
}

if (!EXECUTE) {
  banner('Dry run. Re-run with --execute to apply the swaps.');
} else {
  banner('Applying swaps');
  let ok = 0, fail = 0;
  for (const p of safe) {
    try {
      // Transaction: delete old link, insert new. Run as one query.
      await pg(`
        BEGIN;
        DELETE FROM public.manifest_visits
        WHERE visit_id = ${p.wrong_visit_id} AND manifest_id = ${p.manifest_id};
        INSERT INTO public.manifest_visits (visit_id, manifest_id)
        VALUES (${p.best_gt_visit_id}, ${p.manifest_id})
        ON CONFLICT (visit_id, manifest_id) DO NOTHING;
        COMMIT;
      `);
      ok++;
    } catch (e) {
      fail++;
      console.log(`  FAIL #${p.white_manifest_number}: ${e.message}`);
    }
  }
  console.log(`\nSwaps applied: ${ok}, failed: ${fail}`);
}
