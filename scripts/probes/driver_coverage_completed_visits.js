// "All completed visits must have a driver" — coverage audit.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

function q(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>r.statusCode<300?res(JSON.parse(d)):rej(new Error(`${r.statusCode}: ${d.slice(0,400)}`))); });
    req.on('error', rej); req.write(body); req.end();
  });
}

(async () => {
  console.log('=== ALL completed visits — driver attribution split by source ===');
  console.table(await q(`
    SELECT
      CASE
        WHEN at_links.cnt > 0 AND jb_links.cnt > 0 THEN 'BOTH (jobber+airtable)'
        WHEN jb_links.cnt > 0                      THEN 'jobber only'
        WHEN at_links.cnt > 0                      THEN 'airtable only (cleanup-pending)'
        ELSE                                            'NO links'
      END AS source,
      COUNT(*) AS completed_visits,
      COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM visit_assignments va WHERE va.visit_id=v.id)) AS with_employee,
      COUNT(*) FILTER (WHERE v.vehicle_id IS NOT NULL) AS with_vehicle,
      COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM visit_assignments va WHERE va.visit_id=v.id) OR v.vehicle_id IS NOT NULL) AS with_any_attribution,
      COUNT(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM visit_assignments va WHERE va.visit_id=v.id) AND v.vehicle_id IS NULL) AS missing_attribution
    FROM visits v
    LEFT JOIN LATERAL (SELECT COUNT(*) AS cnt FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber') jb_links ON true
    LEFT JOIN LATERAL (SELECT COUNT(*) AS cnt FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='airtable') at_links ON true
    WHERE v.visit_status='completed'
    GROUP BY source ORDER BY completed_visits DESC;
  `));

  console.log('\n=== Projected POST-CLEANUP state — only visits that will survive ===');
  console.table(await q(`
    -- Visits that will remain after dropping 1,803 phantom AT-only:
    -- = jobber-linked ones + AT-only with a ±2d Jobber match (which we'll
    --   collapse INTO the jobber row, taking only its Airtable ESL).
    SELECT
      COUNT(*) AS completed_visits_post_cleanup,
      COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM visit_assignments va WHERE va.visit_id=v.id)) AS with_employee,
      ROUND(100.0 * COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM visit_assignments va WHERE va.visit_id=v.id)) / COUNT(*), 1) AS pct_with_employee,
      COUNT(*) FILTER (WHERE v.vehicle_id IS NOT NULL) AS with_vehicle,
      ROUND(100.0 * COUNT(*) FILTER (WHERE v.vehicle_id IS NOT NULL) / COUNT(*), 1) AS pct_with_vehicle,
      COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM visit_assignments va WHERE va.visit_id=v.id) OR v.vehicle_id IS NOT NULL) AS any_attribution,
      ROUND(100.0 * COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM visit_assignments va WHERE va.visit_id=v.id) OR v.vehicle_id IS NOT NULL) / COUNT(*), 1) AS pct_any
    FROM visits v
    WHERE v.visit_status='completed'
      AND EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber');
  `));

  console.log('\n=== Jobber-completed visits WITHOUT any driver — by year ===');
  console.table(await q(`
    SELECT
      EXTRACT(YEAR FROM v.visit_date)::int AS year,
      COUNT(*) AS missing_driver,
      MIN(v.visit_date) AS earliest,
      MAX(v.visit_date) AS latest
    FROM visits v
    WHERE v.visit_status='completed'
      AND EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber')
      AND NOT EXISTS (SELECT 1 FROM visit_assignments va WHERE va.visit_id=v.id)
      AND v.vehicle_id IS NULL
    GROUP BY year ORDER BY year DESC LIMIT 20;
  `));

  console.log('\n=== Sample 10 Jobber-completed visits with no attribution ===');
  console.table(await q(`
    SELECT v.id, v.visit_date, c.client_code,
           (SELECT source_id FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber' LIMIT 1) AS jobber_gid,
           v.start_at, v.end_at
    FROM visits v JOIN clients c ON c.id=v.client_id
    WHERE v.visit_status='completed'
      AND EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber')
      AND NOT EXISTS (SELECT 1 FROM visit_assignments va WHERE va.visit_id=v.id)
      AND v.vehicle_id IS NULL
    ORDER BY v.visit_date DESC LIMIT 10;
  `));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
