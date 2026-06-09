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
console.log('=== Recent Jobber clients in raw (last 24h) ===');
console.log(await pg(`
  SELECT data->>'id' AS gid, data->>'name' AS name, data->>'companyName' AS company,
         pulled_at
  FROM raw.jobber_pull_clients
  WHERE pulled_at >= NOW() - INTERVAL '1 hour'
  ORDER BY pulled_at DESC LIMIT 10;
`));
console.log('\n=== Wyn clients in DB now? ===');
console.log(await pg(`
  SELECT id, client_code, name FROM public.clients
  WHERE name ILIKE ANY (ARRAY['%Presidente%','%CU4%','%Nino Gordo%','%Pari Pari%'])
     OR client_code ILIKE '%WYN%';
`));
