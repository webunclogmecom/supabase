// 83_smoke_followups.mjs
// Drill into the 4 warnings surfaced by smoke test 82.

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

banner('1. The 4 SQL-source visit INSERTs at 11:53 today');
console.log(await pg(`
  SELECT al.id AS audit_id, al.changed_at,
         (al.new_row->>'id')::int AS visit_id,
         al.new_row->>'visit_date' AS visit_date,
         al.new_row->>'visit_status' AS status,
         al.new_row->>'title' AS title,
         al.new_row->>'source' AS source
  FROM audit.logs al
  WHERE al.table_name='visits' AND al.operation='INSERT'
    AND al.app_source='sql'
    AND al.changed_at::date = CURRENT_DATE
  ORDER BY al.changed_at DESC LIMIT 10;
`));

banner('2. 11 overdue scheduled visits (past, not yet completed)');
console.log(await pg(`
  SELECT id, visit_date, client_name, client_code, service_type, truck_name
  FROM ops.v_calendar_visit
  WHERE visit_date >= CURRENT_DATE - INTERVAL '14 days'
    AND visit_date <  CURRENT_DATE
    AND visit_status = 'scheduled'
  ORDER BY visit_date LIMIT 20;
`));

banner('3. 4 DERM manifests missing url');
console.log(await pg(`
  SELECT id, white_manifest_number, service_date, client_id,
         derm_manifest_url, derm_address_url, created_at
  FROM public.derm_manifests
  WHERE derm_manifest_url IS NULL
  ORDER BY service_date DESC NULLS LAST LIMIT 10;
`));

banner('4. 8 GT visits missing manifest_visits link (older than 2 weeks)');
console.log(await pg(`
  SELECT v.id, v.visit_date, c.name AS client_name, c.client_code,
         v.derm_required
  FROM public.visits v
  JOIN public.clients c ON c.id = v.client_id
  WHERE v.visit_status = 'completed'
    AND v.visit_date <= CURRENT_DATE - INTERVAL '14 days'
    AND v.visit_date >= CURRENT_DATE - INTERVAL '90 days'
    AND v.service_type = 'GT'
    AND (v.derm_required IS NULL OR v.derm_required = true)
    AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.visit_id = v.id)
  ORDER BY v.visit_date DESC LIMIT 20;
`));

banner('5. 13 properties missing lat/lon');
console.log(await pg(`
  SELECT p.id, p.address, p.city, p.county, p.is_primary,
         c.name AS client_name, c.status AS client_status
  FROM public.properties p
  LEFT JOIN public.clients c ON c.id = p.client_id
  WHERE p.latitude IS NULL OR p.longitude IS NULL
  ORDER BY p.is_primary DESC, c.name LIMIT 20;
`));

banner('6. Samsara webhook health — last 7 days');
console.log(await pg(`
  SELECT DATE_TRUNC('day', created_at) AS day,
         COUNT(*)::int AS events
  FROM public.webhook_events_log
  WHERE source_system='samsara'
    AND created_at >= NOW() - INTERVAL '7 days'
  GROUP BY 1 ORDER BY 1 DESC;
`));
