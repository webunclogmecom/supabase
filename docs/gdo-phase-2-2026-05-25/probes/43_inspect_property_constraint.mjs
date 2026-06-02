import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, { method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'}, body:JSON.stringify({query:sql})});
  return JSON.parse(await r.text());
}

console.log('=== uq_properties_one_primary_per_client definition ===');
console.log(await pg(`SELECT indexname, indexdef FROM pg_indexes WHERE tablename='properties' AND indexname LIKE 'uq_%';`));

console.log('\n=== One failing payload from webhook_events_log (raw_payload sample) ===');
console.log(await pg(`
  SELECT id, event_type, error_message,
    raw_payload->'topic' AS topic,
    raw_payload->'data' AS data
  FROM public.webhook_events_log
  WHERE source_system='jobber' AND status='failed'
    AND created_at >= '2026-05-26T17:57:00Z'
  ORDER BY created_at DESC
  LIMIT 2;
`));

console.log('\n=== Are there clients with multiple is_primary=true rows (CONSTRAINT VIOLATION POSSIBLE)? ===');
console.log(await pg(`
  SELECT client_id, count(*)::int AS primary_count
  FROM public.properties WHERE is_primary=true
  GROUP BY client_id HAVING count(*)>1 ORDER BY 2 DESC LIMIT 10;
`));

console.log('\n=== Check if handleProperty INSERT sets is_primary anywhere (should not, default NULL) ===');
console.log(await pg(`
  SELECT count(*)::int AS null_primary, count(*) FILTER (WHERE is_primary=true)::int AS true_primary,
         count(*) FILTER (WHERE is_primary=false)::int AS false_primary
  FROM public.properties;
`));
