require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROD = process.env.SUPABASE_PROJECT_ID;
function pg(sql) {
  return new Promise((res, rej) => {
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${PROD}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
    }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res(b)); });
    req.on('error', rej);
    req.write(JSON.stringify({query: sql}));
    req.end();
  });
}
(async () => {
  console.log('=== webhook_events_log for visit 2160911401 (092-TCE May 4) ===');
  console.log(await pg(`
    SELECT id, topic, source_id, processed_at, error
    FROM webhook_events_log
    WHERE source_id = '2160911401' OR payload::text LIKE '%2160911401%'
    ORDER BY received_at;
  `));

  console.log('\n=== Drivers + Jobber linkage ===');
  console.log(await pg(`
    SELECT e.id, e.full_name, e.role,
           (SELECT source_id FROM entity_source_links WHERE entity_type='employee' AND entity_id=e.id AND source_system='jobber' LIMIT 1) AS jobber_id
    FROM employees e
    WHERE e.full_name ILIKE '%steven%' OR e.full_name ILIKE '%grecia%' OR e.full_name ILIKE '%jeffry%'
       OR e.role IN ('driver','helper','plumber')
    ORDER BY e.role, e.full_name;
  `));

  console.log('\n=== Daily visit_assignments coverage Apr 25 → May 11 ===');
  console.log(await pg(`
    SELECT v.visit_date,
           COUNT(DISTINCT v.id)::int AS visits,
           COUNT(DISTINCT va.visit_id)::int AS with_assignments,
           COUNT(DISTINCT v.id) - COUNT(DISTINCT va.visit_id) AS gap
    FROM visits v LEFT JOIN visit_assignments va ON va.visit_id=v.id
    WHERE v.visit_date >= '2026-04-25' AND v.visit_status='completed'
    GROUP BY v.visit_date ORDER BY v.visit_date;
  `));

  console.log('\n=== Recent visit-topic webhook events (last 20) ===');
  console.log(await pg(`
    SELECT id, topic, source_id, received_at, processed_at IS NOT NULL AS processed, error IS NOT NULL AS errored
    FROM webhook_events_log
    WHERE topic ILIKE '%visit%' OR topic ILIKE '%job%'
    ORDER BY received_at DESC LIMIT 20;
  `));
})();
