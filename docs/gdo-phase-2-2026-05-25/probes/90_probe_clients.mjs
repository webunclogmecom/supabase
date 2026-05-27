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
// What are the clients tied to manifest 824533?
console.log(await pg(`
  SELECT dm.id, dm.client_id, c.client_code, c.name, dm.service_date, dm.white_manifest_number
  FROM public.derm_manifests dm
  JOIN public.clients c ON c.id = dm.client_id
  WHERE dm.white_manifest_number IN ('824533','824713','824949','816562','821038')
  ORDER BY dm.white_manifest_number, c.client_code;
`));
// And Specialita's entity_source_links
console.log('\n--- Specialita esls + new Wyn-like clients ---');
console.log(await pg(`
  SELECT entity_id, source_system, source_id FROM public.entity_source_links
  WHERE entity_type='client' AND entity_id IN (353,459,295,125,455,282,297,178,300,307,289,57,321,372,348)
  ORDER BY entity_id, source_system;
`));
