import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, { method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'}, body:JSON.stringify({query:sql})});
  return JSON.parse(await r.text());
}
console.log('=== derm_manifests columns ===');
console.log(await pg(`SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='derm_manifests' ORDER BY ordinal_position;`));

console.log('\n=== Client 316 (174-17) DERM manifests ===');
console.log(await pg(`SELECT id, white_manifest_number, white_manifest_url FROM public.derm_manifests WHERE client_id=316 ORDER BY id DESC LIMIT 3;`));

console.log('\n=== Client SASSI lookup ===');
console.log(await pg(`SELECT id, client_code, name, status FROM public.clients WHERE client_code='205-SAS' OR name ILIKE '%SASSI%' OR name ILIKE '%signor%';`));
