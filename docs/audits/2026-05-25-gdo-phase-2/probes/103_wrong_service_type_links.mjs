// 103_wrong_service_type_links.mjs
// Find manifest_visits rows where the linked visit's service_type isn't GT.
// DERM manifests are only issued for grease-trap dumps — they should ONLY
// link to GT visits. Anything else is a webhook misfire.

import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${(await r.text()).slice(0, 600)}`);
  return JSON.parse(await r.text());
}
const banner = (s) => console.log(`\n${'='.repeat(70)}\n${s}\n${'='.repeat(70)}`);

banner('1. manifest_visits where visit.service_type != GT');
console.log(await pg(`
  SELECT mv.visit_id, mv.manifest_id,
         v.visit_date, v.service_type, v.title,
         c.client_code, c.name AS client_name,
         dm.white_manifest_number, dm.service_date AS manifest_date
  FROM public.manifest_visits mv
  JOIN public.visits v ON v.id = mv.visit_id
  JOIN public.clients c ON c.id = v.client_id
  JOIN public.derm_manifests dm ON dm.id = mv.manifest_id
  WHERE v.service_type <> 'GT'
  ORDER BY v.visit_date DESC
  LIMIT 50;
`));

banner('2. For each wrong link — does a CORRECT GT visit exist for the same client+manifest?');
console.log(await pg(`
  WITH wrong AS (
    SELECT mv.visit_id, mv.manifest_id, v.client_id, dm.service_date AS m_date
    FROM public.manifest_visits mv
    JOIN public.visits v ON v.id = mv.visit_id
    JOIN public.derm_manifests dm ON dm.id = mv.manifest_id
    WHERE v.service_type <> 'GT'
  )
  SELECT w.visit_id AS wrong_visit_id, w.manifest_id, w.m_date,
         array_agg(json_build_object(
           'gt_visit_id', v2.id,
           'gt_visit_date', v2.visit_date,
           'gap_days', ABS(v2.visit_date - w.m_date)
         ) ORDER BY ABS(v2.visit_date - w.m_date)) AS gt_candidates
  FROM wrong w
  LEFT JOIN public.visits v2
    ON v2.client_id = w.client_id
   AND v2.service_type = 'GT'
   AND v2.visit_status = 'completed'
   AND v2.visit_date BETWEEN w.m_date - INTERVAL '15 days' AND w.m_date + INTERVAL '15 days'
   AND v2.id <> w.visit_id
  GROUP BY w.visit_id, w.manifest_id, w.m_date
  ORDER BY w.m_date DESC;
`));
