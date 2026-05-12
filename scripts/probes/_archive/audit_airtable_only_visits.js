// How many visits in our DB exist ONLY in Airtable (no Jobber link)?
// These violate the trust hierarchy — visits should be Jobber-canonical.
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
  console.log('=== Visits by source-system pattern ===');
  console.table(await q(`
    SELECT
      CASE
        WHEN at_links.cnt > 0 AND jb_links.cnt > 0 THEN 'BOTH (jobber + airtable)'
        WHEN jb_links.cnt > 0                      THEN 'jobber only'
        WHEN at_links.cnt > 0                      THEN 'airtable only'
        ELSE                                            'NO links'
      END AS source_pattern,
      COUNT(*) AS n_visits
    FROM visits v
    LEFT JOIN LATERAL (SELECT COUNT(*) AS cnt FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber') jb_links ON true
    LEFT JOIN LATERAL (SELECT COUNT(*) AS cnt FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='airtable') at_links ON true
    GROUP BY source_pattern ORDER BY n_visits DESC;
  `));

  console.log('\n=== Airtable-only visits broken down by year ===');
  console.table(await q(`
    SELECT
      EXTRACT(YEAR FROM v.visit_date)::int AS year,
      v.visit_status,
      COUNT(*) AS n
    FROM visits v
    WHERE EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='airtable')
      AND NOT EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber')
    GROUP BY year, v.visit_status
    ORDER BY year DESC, v.visit_status;
  `));

  console.log('\n=== When did Jobber visits start (earliest Jobber-linked visit_date)? ===');
  console.table(await q(`
    SELECT
      MIN(v.visit_date) AS earliest_jobber_visit,
      MAX(v.visit_date) AS latest_jobber_visit,
      COUNT(*) AS total_jobber_visits
    FROM visits v
    WHERE EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber');
  `));

  console.log('\n=== Airtable-only visits AFTER Jobber went live (these violate the trust hierarchy) ===');
  console.table(await q(`
    WITH jobber_start AS (
      SELECT MIN(v.visit_date) AS d FROM visits v
      WHERE EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber')
    )
    SELECT
      EXTRACT(YEAR FROM v.visit_date)::int AS year,
      v.visit_status,
      COUNT(*) AS n
    FROM visits v, jobber_start
    WHERE EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='airtable')
      AND NOT EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber')
      AND v.visit_date >= jobber_start.d
    GROUP BY year, v.visit_status
    ORDER BY year DESC, v.visit_status;
  `));

  console.log('\n=== visit_status values across all visits ===');
  console.table(await q(`
    SELECT
      v.visit_status,
      CASE
        WHEN at_links.cnt > 0 AND jb_links.cnt > 0 THEN 'BOTH'
        WHEN jb_links.cnt > 0                      THEN 'jobber'
        ELSE                                            'airtable'
      END AS src,
      COUNT(*) AS n
    FROM visits v
    LEFT JOIN LATERAL (SELECT COUNT(*) AS cnt FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber') jb_links ON true
    LEFT JOIN LATERAL (SELECT COUNT(*) AS cnt FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='airtable') at_links ON true
    GROUP BY v.visit_status, src
    ORDER BY v.visit_status, src;
  `));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
