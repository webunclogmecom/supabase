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
// All manifest_visits links for Claudie (client 372)
console.log(await pg(`
  SELECT mv.visit_id, mv.manifest_id, v.visit_date, dm.service_date, dm.white_manifest_number
  FROM public.manifest_visits mv
  JOIN public.visits v ON v.id=mv.visit_id
  JOIN public.derm_manifests dm ON dm.id=mv.manifest_id
  WHERE v.client_id=372 OR dm.client_id=372
  ORDER BY v.visit_date DESC LIMIT 10;
`));
