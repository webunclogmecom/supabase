// 76_calendar_audit_drilldown.mjs
// Investigate the 5 anomalies from probe 75:
// 1. Cancelled visit 5138 showing in v_calendar_visit
// 2. Status↔completed_at mismatch (1 visit)
// 3. Missing Jobber link (1 jobber-source visit)
// 4. Duplicate candidates: client 369 + client 460
// 5. Airtable-linked visit (1)

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

banner('1. Cancelled visit 5138 — full detail + audit trail');
console.log(await pg(`
  SELECT id, visit_date, client_id, visit_status, completed_at, source,
         created_at, updated_at
  FROM public.visits WHERE id = 5138;
`));
console.log('\n--- audit trail for visit 5138 ---');
console.log(await pg(`
  SELECT id, app_source, operation, changed_at,
         old_row->>'visit_status' AS old_status,
         new_row->>'visit_status' AS new_status
  FROM audit.logs
  WHERE table_name='visits' AND (COALESCE(new_row->>'id', old_row->>'id'))::int = 5138
  ORDER BY changed_at DESC LIMIT 10;
`));

banner('2. Status↔completed_at mismatch — find the row');
console.log(await pg(`
  SELECT id, visit_date, client_id, visit_status, completed_at, source
  FROM public.visits
  WHERE visit_date >= '2026-05-01' AND visit_date < '2026-06-01'
    AND visit_status <> 'completed' AND completed_at IS NOT NULL;
`));

banner('3. Missing Jobber link — jobber-source visit without entity_source_links');
console.log(await pg(`
  SELECT v.id, v.visit_date, c.name, c.client_code, v.visit_status, v.source
  FROM public.visits v
  LEFT JOIN public.clients c ON c.id = v.client_id
  LEFT JOIN public.entity_source_links esl
    ON esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber'
  WHERE v.visit_date >= '2026-05-01' AND v.visit_date < '2026-06-01'
    AND v.source = 'jobber'
    AND esl.id IS NULL;
`));

banner('4a. Duplicate client 369 — full detail of both visits');
console.log(await pg(`
  SELECT v.id, v.visit_date, c.name, c.client_code, v.service_type,
         v.visit_status, v.completed_at, v.invoice_id, v.title,
         v.vehicle_id, vh.name AS truck
  FROM public.visits v
  JOIN public.clients c ON c.id = v.client_id
  LEFT JOIN public.vehicles vh ON vh.id = v.vehicle_id
  WHERE v.id IN (5081, 5082);
`));

banner('4b. Duplicate client 460 — full detail of both visits');
console.log(await pg(`
  SELECT v.id, v.visit_date, c.name, c.client_code, v.service_type,
         v.visit_status, v.completed_at, v.invoice_id, v.title,
         v.vehicle_id, vh.name AS truck
  FROM public.visits v
  JOIN public.clients c ON c.id = v.client_id
  LEFT JOIN public.vehicles vh ON vh.id = v.vehicle_id
  WHERE v.id IN (5125, 5127);
`));

banner('5. Airtable-linked May 2026 visit');
console.log(await pg(`
  SELECT v.id, v.visit_date, c.name, c.client_code, v.visit_status, v.source,
         esl.source_system, esl.source_id, esl.synced_at
  FROM public.visits v
  JOIN public.clients c ON c.id = v.client_id
  JOIN public.entity_source_links esl
    ON esl.entity_type='visit' AND esl.entity_id=v.id
  WHERE v.visit_date >= '2026-05-01' AND v.visit_date < '2026-06-01'
    AND esl.source_system = 'airtable';
`));
