// 80_remove_anomaly_visits.mjs
// Hard-delete two anomaly visits:
//   - 4326 (Mila May 13): no matching Jobber visit; orphan with stale source='jobber' tag
//   - 5138 (17 Restaurant May 27): test residue from this session
//
// Both have no value as historical records (no upstream source). FK CASCADE
// will handle visit_assignments and manifest_visits. entity_source_links is
// already absent for both. Audit trail logs the DELETEs with app_source='sql'.

import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 600)}`);
  return JSON.parse(body);
}
const banner = (s) => console.log(`\n${'='.repeat(70)}\n${s}\n${'='.repeat(70)}`);

banner('A. FK references to the doomed visits');
console.log(await pg(`
  SELECT 'visit_assignments' AS table_name,
         COUNT(*) FILTER (WHERE visit_id = 4326) AS for_4326,
         COUNT(*) FILTER (WHERE visit_id = 5138) AS for_5138
  FROM public.visit_assignments
  UNION ALL
  SELECT 'manifest_visits',
         COUNT(*) FILTER (WHERE visit_id = 4326),
         COUNT(*) FILTER (WHERE visit_id = 5138)
  FROM public.manifest_visits
  UNION ALL
  SELECT 'entity_source_links (visit type)',
         COUNT(*) FILTER (WHERE entity_id = 4326 AND entity_type='visit'),
         COUNT(*) FILTER (WHERE entity_id = 5138 AND entity_type='visit')
  FROM public.entity_source_links;
`));

banner('B. Before — current state');
console.log(await pg(`
  SELECT id, visit_date, client_id, visit_status, source, title
  FROM public.visits WHERE id IN (4326, 5138)
  ORDER BY id;
`));

banner('B.5 Remove the orphaned empty migration note on 4326');
console.log(await pg(`
  DELETE FROM public.notes
  WHERE visit_id = 4326 AND body = '' AND source = 'jobber_migration'
  RETURNING id, visit_id, body, source;
`));

banner('C. DELETE visit 4326 (Mila orphan) + 5138 (test residue)');
console.log(await pg(`
  DELETE FROM public.visits
  WHERE id IN (4326, 5138)
  RETURNING id, visit_date, client_id, visit_status, source;
`));

banner('D. After — should be empty');
console.log(await pg(`
  SELECT id FROM public.visits WHERE id IN (4326, 5138);
`));

banner('E. Audit log captured the DELETEs');
console.log(await pg(`
  SELECT id, app_source, operation, changed_at,
         (old_row->>'id')::int AS visit_id,
         old_row->>'visit_status' AS old_status
  FROM audit.logs
  WHERE table_name='visits'
    AND operation='DELETE'
    AND (old_row->>'id')::int IN (4326, 5138)
  ORDER BY changed_at DESC LIMIT 5;
`));

banner('F. New May 2026 totals');
console.log(await pg(`
  SELECT
    COUNT(*)::int AS total,
    COUNT(*) FILTER (WHERE visit_status='completed')::int AS completed,
    COUNT(*) FILTER (WHERE visit_status='scheduled')::int AS scheduled,
    COUNT(*) FILTER (WHERE visit_status='cancelled')::int AS cancelled
  FROM public.visits
  WHERE visit_date >= '2026-05-01' AND visit_date < '2026-06-01';
`));
