// 78_check_mila_in_jobber.mjs
// Mila (043-MIL) visit 4326 on 2026-05-13 has source='jobber' but no
// entity_source_links row. Verify against raw.jobber_pull_visits whether
// a corresponding Jobber visit exists for client_id=Mila on that date.

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

banner('A. raw.jobber_pull_visits — schema');
console.log(await pg(`
  SELECT column_name, data_type
  FROM information_schema.columns
  WHERE table_schema='raw' AND table_name='jobber_pull_visits'
  ORDER BY ordinal_position;
`));

banner('B. Mila Jobber client id (via entity_source_links)');
console.log(await pg(`
  SELECT source_id FROM public.entity_source_links
  WHERE entity_type='client' AND entity_id=43 AND source_system='jobber';
`));
// Mila client_id is 43 per the codes table? Let me also lookup by client_code.

banner('C. Mila client lookup by code');
console.log(await pg(`
  SELECT id, client_code, name FROM public.clients
  WHERE client_code = '043-MIL';
`));

banner('D. Search raw.jobber_pull_visits for any May 2026 visit on Mila client');
// First get Mila's Jobber client gid, then filter.
console.log(await pg(`
  WITH mila AS (
    SELECT esl.source_id AS jobber_client_gid
    FROM public.clients c
    JOIN public.entity_source_links esl
      ON esl.entity_type='client' AND esl.entity_id=c.id AND esl.source_system='jobber'
    WHERE c.client_code='043-MIL'
  )
  SELECT *
  FROM raw.jobber_pull_visits jv, mila
  WHERE jv.data::text LIKE '%' || mila.jobber_client_gid || '%'
    AND (jv.data->>'startAt')::timestamptz >= '2026-05-01'
    AND (jv.data->>'startAt')::timestamptz < '2026-06-01'
  LIMIT 5;
`));

banner('E. Check raw.jobber_pull_visits column list first if D errored');
console.log(await pg(`
  SELECT * FROM raw.jobber_pull_visits LIMIT 1;
`));
