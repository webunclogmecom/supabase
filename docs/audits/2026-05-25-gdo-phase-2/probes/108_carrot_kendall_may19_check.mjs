// 108_carrot_kendall_may19_check.mjs
// Fred reports: The carrot express Kendall (077-TCE) visit on 2026-05-19
// was un-completed in Jobber but our DB still shows it as completed, so
// the DERM Tracker (which filters completed-only) still surfaces it.
// Find the DB visit + Jobber raw side + recent audit + decide the fix.
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

banner('1. The carrot express Kendall visit on May 19 in DB');
console.log(await pg(`
  SELECT v.id, v.visit_date, v.start_at, v.completed_at, v.visit_status,
         v.service_type, v.title, v.invoice_id, v.updated_at,
         (SELECT esl.source_id FROM public.entity_source_links esl
          WHERE esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber') AS jb_gid
  FROM public.visits v
  JOIN public.clients c ON c.id = v.client_id
  WHERE c.client_code = '077-TCE'
    AND v.visit_date = '2026-05-19'
  ORDER BY v.start_at;
`));

banner('2. ALL Kendall May visits — give the broader context');
console.log(await pg(`
  SELECT v.id, v.visit_date, v.visit_status, v.service_type, v.title,
         v.completed_at, v.updated_at
  FROM public.visits v
  JOIN public.clients c ON c.id = v.client_id
  WHERE c.client_code='077-TCE'
    AND v.visit_date BETWEEN '2026-05-01' AND '2026-05-31'
  ORDER BY v.visit_date;
`));

banner('3. Jobber raw visit for the same visit (lookup by job/start)');
// Find by title pattern (Jobber title contains client code) + date range
console.log(await pg(`
  SELECT id, data->>'id' AS jb_visit_gid,
         data->>'title' AS title,
         data->>'startAt' AS start_at,
         data->>'completedAt' AS completed_at,
         data->>'visitStatus' AS visit_status,
         data->>'completedBy' AS completed_by,
         data->>'_cursorTime' AS cursor_time,
         pulled_at
  FROM raw.jobber_pull_visits
  WHERE data->>'title' ILIKE '%077-TCE%'
    AND (data->>'startAt')::timestamptz BETWEEN '2026-05-18' AND '2026-05-21'
  ORDER BY (data->>'startAt')::timestamptz DESC;
`));

banner('4. Recent audit.logs for the Kendall visit');
console.log(await pg(`
  SELECT al.id, al.app_source, al.operation, al.changed_at,
         al.old_row->>'visit_status' AS old_status,
         al.new_row->>'visit_status' AS new_status,
         al.old_row->>'completed_at' AS old_completed_at,
         al.new_row->>'completed_at' AS new_completed_at
  FROM audit.logs al
  WHERE al.table_name='visits'
    AND (al.new_row->>'id')::int IN (
      SELECT v.id FROM public.visits v
      JOIN public.clients c ON c.id=v.client_id
      WHERE c.client_code='077-TCE' AND v.visit_date='2026-05-19'
    )
  ORDER BY al.changed_at DESC LIMIT 10;
`));
