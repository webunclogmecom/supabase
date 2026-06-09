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
  SELECT
    (SELECT COUNT(*)::int FROM public.derm_manifests) AS manifests,
    (SELECT COUNT(*)::int FROM public.entity_source_links
     WHERE entity_type='derm_manifest' AND source_system='airtable') AS at_links,
    (SELECT COUNT(*)::int FROM public.webhook_events_log
     WHERE source_system='airtable' AND created_at > NOW() - INTERVAL '10 minutes') AS recent_at_webhooks;
`));
