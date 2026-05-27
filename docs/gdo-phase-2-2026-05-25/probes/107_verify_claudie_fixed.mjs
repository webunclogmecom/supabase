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
console.log('=== visit 5099 (Claudie May 14 GT) is now linked? ===');
console.log(await pg(`
  SELECT v.id AS visit_id, v.visit_date, v.service_type, v.title,
         mv.manifest_id, dm.white_manifest_number, dm.derm_manifest_url IS NOT NULL AS has_pdf
  FROM public.visits v
  LEFT JOIN public.manifest_visits mv ON mv.visit_id=v.id
  LEFT JOIN public.derm_manifests dm ON dm.id=mv.manifest_id
  WHERE v.id=5099;
`));
console.log('\n=== Remaining wrong-service-type links (should be only LS Bayshore now) ===');
console.log(await pg(`
  SELECT v.service_type, COUNT(*)::int AS n
  FROM public.manifest_visits mv
  JOIN public.visits v ON v.id=mv.visit_id
  WHERE v.service_type <> 'GT'
  GROUP BY v.service_type ORDER BY v.service_type;
`));
