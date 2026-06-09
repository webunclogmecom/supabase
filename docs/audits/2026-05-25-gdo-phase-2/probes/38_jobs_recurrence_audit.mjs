// 38_jobs_recurrence_audit.mjs
// Two questions:
//   (1) What columns does public.jobs have? Does it carry recurrence/frequency
//       info from Jobber that we could use as a fallback for frequency_days
//       when service_configs is empty?
//   (2) For the visits showing NULL frequency in v_calendar_visit, are they
//       linked to a recurring job, a one-off, or no job at all?

import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 600)}`);
  return JSON.parse(body);
}

console.log('=== A) public.jobs column inventory ===');
console.log(await pg(`
  SELECT column_name, data_type, is_nullable
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='jobs'
  ORDER BY ordinal_position;
`));

console.log('\n=== B) Sample job for Aromas del Peru CL visit (id=3943, job_id=566) ===');
console.log(await pg(`
  SELECT j.*
  FROM public.jobs j
  WHERE j.id = 566;
`));

console.log('\n=== C) Sample job for the Pura Vida May 1 visit (id=1794, has frequency 60) ===');
console.log(await pg(`
  SELECT v.id AS visit_id, v.job_id, j.title AS job_title, j.created_at AS job_created
  FROM public.visits v LEFT JOIN public.jobs j ON j.id=v.job_id
  WHERE v.id=1794;
`));

console.log('\n=== D) For visits in May with NULL frequency_days, are they ON a recurring-looking job? ===');
console.log('  (group by # visits on the same job_id — recurring jobs have many visits, one-offs have 1)\n');
console.log(await pg(`
  WITH null_freq_visits AS (
    SELECT id, job_id, client_name, service_type
    FROM ops.v_calendar_visit
    WHERE visit_date BETWEEN '2026-05-01' AND '2026-05-31'
      AND frequency_days IS NULL
      AND job_id IS NOT NULL
  ),
  job_visit_counts AS (
    SELECT job_id, count(*)::int AS visits_on_job
    FROM public.visits
    WHERE job_id IS NOT NULL
    GROUP BY job_id
  )
  SELECT
    CASE
      WHEN jvc.visits_on_job IS NULL THEN 'no_job'
      WHEN jvc.visits_on_job = 1 THEN 'one_off (1 visit)'
      WHEN jvc.visits_on_job BETWEEN 2 AND 5 THEN 'short_recur (2-5)'
      WHEN jvc.visits_on_job BETWEEN 6 AND 20 THEN 'recurring (6-20)'
      ELSE 'heavy_recurring (20+)'
    END AS pattern,
    count(*)::int AS visits_in_may_with_null_freq
  FROM null_freq_visits nfv
  LEFT JOIN job_visit_counts jvc ON jvc.job_id = nfv.job_id
  GROUP BY 1
  ORDER BY 2 DESC;
`));

console.log('\n=== E) For Aromas del Peru — list all visits + job they belong to ===');
console.log(await pg(`
  SELECT v.id, v.visit_date, v.service_type, v.visit_status, v.job_id,
         (SELECT count(*) FROM public.visits WHERE job_id=v.job_id) AS sibling_visits_on_job,
         (SELECT title FROM public.jobs WHERE id=v.job_id) AS job_title
  FROM public.visits v
  WHERE v.client_id = 450  -- Aromas del Peru
  ORDER BY v.visit_date;
`));

console.log('\n=== F) Same for Myka Brickell FT LLC (id=348, 6 missing CL visits) ===');
console.log(await pg(`
  SELECT v.id, v.visit_date, v.service_type, v.visit_status, v.job_id,
         (SELECT count(*) FROM public.visits WHERE job_id=v.job_id) AS sibling_visits_on_job,
         (SELECT title FROM public.jobs WHERE id=v.job_id) AS job_title
  FROM public.visits v
  WHERE v.client_id = 348
  ORDER BY v.visit_date;
`));
