// 93_specialita_relink_and_wyn_jobber.mjs
// (1) Add the missing Airtable entity_source_link for Specialita (client 353).
// (2) Probe Jobber raw clients/visits more broadly for Wyn entries —
//     name/companyName/title/services_label — to determine whether the 4 Wyn
//     restaurants exist in Jobber at all.
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

banner('1. Add Specialita AT entity_source_link (idempotent)');
console.log(await pg(`
  INSERT INTO public.entity_source_links
    (entity_type, entity_id, source_system, source_id, match_method, synced_at)
  VALUES
    ('client', 353, 'airtable', 'recLwM4gKc5DFFxd0', 'name_fallback', NOW())
  ON CONFLICT (entity_type, entity_id, source_system) DO UPDATE
    SET source_id = EXCLUDED.source_id, synced_at = NOW()
  RETURNING id, entity_type, entity_id, source_system, source_id;
`));

banner('2. Broad search of Jobber raw clients (any JSON path) for Wyn restaurants');
console.log(await pg(`
  SELECT id, data->>'id' AS jobber_gid,
         data->>'name' AS name,
         data->>'companyName' AS company,
         data->>'firstName' AS first_name,
         data->>'lastName' AS last_name,
         pulled_at
  FROM raw.jobber_pull_clients
  WHERE data::text ILIKE ANY (ARRAY['%Presidente%','%CU4%','%Nino Gordo%','%Pari Pari%','%-WYN%'])
  ORDER BY pulled_at DESC LIMIT 20;
`));

banner('3. Broad search of Jobber raw VISITS for Wyn (title often carries client code)');
console.log(await pg(`
  SELECT id, data->>'id' AS jobber_visit_gid,
         data->>'title' AS title,
         data->>'startAt' AS start_at,
         data->'client'->>'id' AS jobber_client_gid
  FROM raw.jobber_pull_visits
  WHERE data->>'title' ILIKE ANY (ARRAY['%Presidente%','%CU4%','%Nino Gordo%','%Pari Pari%','%-WYN%','%217-WYN%','%218-WYN%','%219-WYN%','%220-WYN%'])
  ORDER BY (data->>'startAt')::timestamptz DESC LIMIT 20;
`));

banner('4. Most recent Jobber raw client pull timestamp');
console.log(await pg(`
  SELECT MAX(pulled_at) AS latest_pull,
         MAX(ingested_at) AS latest_ingest,
         COUNT(*)::int AS total_rows
  FROM raw.jobber_pull_clients;
`));
