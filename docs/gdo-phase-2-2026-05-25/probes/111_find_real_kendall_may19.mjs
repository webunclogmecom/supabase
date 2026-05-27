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
console.log('=== Any visit starting around May 19 04:00 (UTC ± timezones) ===');
console.log(await pg(`
  SELECT v.id, v.visit_date, v.start_at, v.completed_at, v.visit_status,
         v.service_type, v.title, c.client_code, c.name AS client_name
  FROM public.visits v
  JOIN public.clients c ON c.id=v.client_id
  WHERE v.start_at BETWEEN '2026-05-19T00:00:00Z' AND '2026-05-19T12:00:00Z'
    AND v.title ILIKE '%077-TCE%'
  ORDER BY v.start_at;
`));

console.log('\n=== Jobber job number 66 - what is it ===');
console.log(await pg(`
  SELECT id, data->>'id' AS jobber_job_gid,
         data->>'jobNumber' AS job_number,
         data->>'title' AS title,
         data->'client'->>'name' AS client_name,
         data->'client'->>'companyName' AS company
  FROM raw.jobber_pull_jobs
  WHERE data->>'jobNumber' = '66';
`));

console.log('\n=== Public jobs table — what is job_id=66 ===');
console.log(await pg(`
  SELECT id, client_id, title, status, job_number
  FROM public.jobs WHERE id=66 OR job_number=66;
`));

console.log('\n=== Latest 3 raw jobber visits for ANY carrot express location ===');
console.log(await pg(`
  SELECT data->>'id' AS jb_visit_gid,
         data->>'title' AS title,
         data->>'startAt' AS start_at,
         data->>'completedAt' AS completed_at,
         data->>'visitStatus' AS status,
         data->'job'->>'jobNumber' AS job_number,
         pulled_at
  FROM raw.jobber_pull_visits
  WHERE data->>'title' ILIKE '%carrot%'
    AND (data->>'startAt')::timestamptz BETWEEN '2026-05-18' AND '2026-05-21'
  ORDER BY (data->>'startAt')::timestamptz;
`));
