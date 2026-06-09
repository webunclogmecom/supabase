// 94_wyn_via_jobber_visits.mjs
// Find all Jobber visit references to Wyn restaurants (Presidente, CU4, Nino
// Gordo, Pari Pari) — then deduce the Jobber client GIDs we need to pull.
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

banner('All Jobber raw visits whose title mentions Wyn restaurants');
const names = ['Presidente','CU4','Nino Gordo','Pari Pari'];
const orClauses = names.map(n => `data->>'title' ILIKE '%${n}%'`).join(' OR ');
console.log(await pg(`
  SELECT data->>'title' AS title,
         data->>'startAt' AS start_at,
         data->'client'->>'id' AS jobber_client_gid,
         data->'client'->>'name' AS client_name
  FROM raw.jobber_pull_visits
  WHERE ${orClauses}
  ORDER BY (data->>'startAt')::timestamptz DESC LIMIT 40;
`));

banner('Distinct Wyn client GIDs discovered in visits');
console.log(await pg(`
  SELECT DISTINCT data->'client'->>'id' AS jobber_client_gid,
                  data->'client'->>'name' AS client_name,
                  MIN(data->>'title') AS sample_title,
                  COUNT(*)::int AS visit_count
  FROM raw.jobber_pull_visits
  WHERE ${orClauses}
  GROUP BY 1, 2;
`));
