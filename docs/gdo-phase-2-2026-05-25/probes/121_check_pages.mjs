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
console.log(await pg(`
  SELECT id, white_manifest_number,
    LEFT(derm_manifest_url, 80) AS m1,
    coalesce(array_length(derm_manifest_extra_urls,1),0) AS m_extra_n,
    LEFT(derm_address_url, 80) AS a1,
    coalesce(array_length(derm_address_extra_urls,1),0) AS a_extra_n,
    derm_address_extra_urls
  FROM public.derm_manifests
  WHERE white_manifest_number = '825167' OR id = 1041
  ORDER BY id DESC LIMIT 5;
`));
