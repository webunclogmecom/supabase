// 91_wyn_clients_origin.mjs
// Find where the 4 Wyn clients (217/218/219/220 — Presidente, CU4, Nino Gordo,
// Pari Pari) live in upstream systems. Also Specialita name fix.

import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${(await r.text()).slice(0, 600)}`);
  return JSON.parse(await r.text());
}

async function fetchAll(table) {
  const all = [];
  let offset = null;
  do {
    const q = new URLSearchParams();
    q.set('pageSize', '100');
    if (offset) q.set('offset', offset);
    const r = await fetch(`https://api.airtable.com/v0/${AT_BASE}/${encodeURIComponent(table)}?${q}`, {
      headers: { Authorization: `Bearer ${AT_KEY}` },
    });
    const j = await r.json();
    all.push(...(j.records || []));
    offset = j.offset;
  } while (offset);
  return all;
}
const banner = (s) => console.log(`\n${'='.repeat(70)}\n${s}\n${'='.repeat(70)}`);

banner('A. Search AT Clients table for Wyn restaurants');
const atClients = await fetchAll('Clients');
const targets = ['Presidente','CU4','Nino Gordo','Pari Pari','Le Specialista','Specialista','Specialita'];
const matches = atClients.filter(r => {
  const name = String((r.fields || {})['Client Name'] || (r.fields || {})['Name'] || '');
  return targets.some(t => name.toLowerCase().includes(t.toLowerCase()));
});
matches.forEach(r => {
  const f = r.fields || {};
  console.log(`  AT ${r.id}  code=${f['Client Code #3'] || f['Client Code'] || '—'}  name="${f['Client Name'] || f['Name']}"  status=${f['ACTIVE/INACTIVE'] || '—'}`);
});

banner('B. Search Jobber raw clients for Wyn restaurants');
console.log(await pg(`
  SELECT id, data->>'id' AS jobber_gid, data->>'name' AS name, data->>'companyName' AS company
  FROM raw.jobber_pull_clients
  WHERE data->>'name' ILIKE ANY (ARRAY['%Presidente%','%CU4%','%Nino Gordo%','%Pari Pari%','%Specialista%','%Specialita%'])
     OR data->>'companyName' ILIKE ANY (ARRAY['%Presidente%','%CU4%','%Nino Gordo%','%Pari Pari%','%Specialista%','%Specialita%']);
`));

banner('C. Specialita existing row in DB + entity_source_links');
console.log(await pg(`
  SELECT c.id, c.client_code, c.name, c.status,
         json_agg(json_build_object('src',esl.source_system,'id',esl.source_id)) AS links
  FROM public.clients c
  LEFT JOIN public.entity_source_links esl
    ON esl.entity_type='client' AND esl.entity_id=c.id
  WHERE c.id=353
  GROUP BY c.id;
`));
