import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  return JSON.parse(await r.text());
}
console.log('=== All Claudie May 2026 GT visits ===');
console.log(await pg(`
  SELECT v.id, v.visit_date, v.start_at, v.end_at, v.completed_at, v.visit_status,
         v.service_type, v.title, v.invoice_id,
         (SELECT esl.source_id FROM public.entity_source_links esl
          WHERE esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber') AS jobber_visit_gid
  FROM public.visits v
  WHERE v.client_id=372 AND v.visit_date BETWEEN '2026-05-01' AND '2026-05-31'
  ORDER BY v.visit_date;
`));
console.log('\n=== Claudie Jobber raw visits in May ===');
console.log(await pg(`
  SELECT data->>'id' AS jobber_visit_gid,
         data->>'title' AS title,
         data->>'startAt' AS start_at,
         data->>'completedAt' AS completed_at,
         data->>'visitStatus' AS status
  FROM raw.jobber_pull_visits
  WHERE data->'client'->>'id' = 'Z2lkOi8vSm9iYmVyL0NsaWVudC8xMDA4NTgyNjA='
    AND (data->>'startAt')::timestamptz BETWEEN '2026-05-01' AND '2026-05-31'
  ORDER BY (data->>'startAt')::timestamptz;
`));
