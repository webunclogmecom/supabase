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
const banner = (s) => console.log(`\n${'='.repeat(70)}\n${s}\n${'='.repeat(70)}`);

const VISIT_GID = 'Z2lkOi8vSm9iYmVyL1Zpc2l0LzIxODI3NTM0Mzk=';

banner('Webhook events for Kendall visit (2182753439) in last 7 days');
console.log(await pg(`
  SELECT id, source_system, event_type, event_id, status, processed_at, created_at,
         processing_ms, COALESCE(error_message, '') AS err
  FROM public.webhook_events_log
  WHERE source_system='jobber'
    AND (payload::text LIKE '%2182753439%')
    AND created_at >= NOW() - INTERVAL '7 days'
  ORDER BY created_at DESC LIMIT 20;
`));

banner('Most recent VISIT_UPDATE jobber webhooks (any visit) in last 12h');
console.log(await pg(`
  SELECT id, event_type, status, created_at, processed_at, processing_ms,
         entity_type, entity_id, COALESCE(error_message,'') AS err
  FROM public.webhook_events_log
  WHERE source_system='jobber'
    AND event_type LIKE '%VISIT%'
    AND created_at >= NOW() - INTERVAL '12 hours'
  ORDER BY created_at DESC LIMIT 20;
`));

banner('Any failed jobber webhooks in last 24h');
console.log(await pg(`
  SELECT id, event_type, status, error_message, created_at
  FROM public.webhook_events_log
  WHERE source_system='jobber'
    AND status <> 'success'
    AND created_at >= NOW() - INTERVAL '24 hours'
  ORDER BY created_at DESC LIMIT 20;
`));
