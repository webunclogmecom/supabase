// 42_check_remaining_webhook_failures.mjs
// What property failures remain post-patch deploy (17:57 UTC)?

import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 500)}`);
  return JSON.parse(body);
}

console.log('=== PROPERTY_UPDATE failures since deploy 17:57 UTC ===');
console.log(await pg(`
  SELECT
    event_type,
    error_message,
    count(*)::int AS occurrences,
    min(created_at)::text AS first_occurred,
    max(created_at)::text AS last_occurred
  FROM public.webhook_events_log
  WHERE source_system='jobber'
    AND status='failed'
    AND created_at >= '2026-05-26T17:57:00Z'
  GROUP BY event_type, error_message
  ORDER BY occurrences DESC;
`));

console.log('\n=== Overall jobber failure count (since deploy) ===');
console.log(await pg(`
  SELECT count(*)::int AS total_failures_since_deploy
  FROM public.webhook_events_log
  WHERE source_system='jobber' AND status='failed'
    AND created_at >= '2026-05-26T17:57:00Z';
`));

console.log('\n=== Clients count drift after full sync ===');
console.log(await pg(`
  SELECT
    (SELECT count(*) FROM public.clients) AS total_clients,
    (SELECT count(*) FROM public.clients WHERE status='ACTIVE') AS active,
    (SELECT count(*) FROM public.clients WHERE status='RECURRING') AS recurring,
    (SELECT count(*) FROM public.clients WHERE status='PAUSED') AS paused,
    (SELECT count(*) FROM public.clients WHERE status='INACTIVE') AS inactive;
`));

console.log('\n=== Properties count ===');
console.log(await pg(`SELECT count(*)::int AS total_properties FROM public.properties;`));
