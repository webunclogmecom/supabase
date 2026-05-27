// 89_check_wyn_clients.mjs
// 5 of the 7 unlinkable AT DERM records reference clients our DB doesn't
// have. Check whether they exist at all under any code variation.
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

banner('Clients with code containing WYN or SPE or matching names');
console.log(await pg(`
  SELECT id, client_code, name, status
  FROM public.clients
  WHERE client_code ILIKE '%WYN%'
     OR client_code ILIKE '%SPE%'
     OR name ILIKE '%Nino Gordo%'
     OR name ILIKE '%CU4%'
     OR name ILIKE '%Pari Pari%'
     OR name ILIKE '%Presidente%'
     OR name ILIKE '%Le Specialista%'
     OR name ILIKE '%Specialista%'
  ORDER BY client_code;
`));

banner('Anyone with the highest client_code numbers (likely the newest clients)');
console.log(await pg(`
  SELECT id, client_code, name, status, created_at
  FROM public.clients
  WHERE client_code ~ '^2[1-2][0-9]-'
  ORDER BY client_code;
`));
