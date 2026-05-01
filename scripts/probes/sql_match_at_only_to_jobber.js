// Cross-reference AT-only visits with Jobber-linked visits in OUR DB
// (not via Jobber API — we already have all the Jobber visits we've pulled).
// Same client + date ±N days = link rather than delete.
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
  for (const window of [0, 1, 2, 7]) {
    const r = await q(`
      WITH at_only AS (
        SELECT v.id, v.client_id, v.visit_date,
               (SELECT source_id FROM entity_source_links
                 WHERE entity_type='visit' AND entity_id=v.id AND source_system='airtable' LIMIT 1) AS at_id
        FROM visits v
        WHERE EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='airtable')
          AND NOT EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber')
      ),
      jobber_visits AS (
        SELECT v.id, v.client_id, v.visit_date
        FROM visits v
        WHERE EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber')
      ),
      matches AS (
        SELECT
          at.id AS at_visit_id,
          at.at_id,
          (
            SELECT jv.id FROM jobber_visits jv
            WHERE jv.client_id = at.client_id
              AND ABS(jv.visit_date - at.visit_date) <= ${window}
            ORDER BY ABS(jv.visit_date - at.visit_date), jv.id
            LIMIT 1
          ) AS matched_jobber_visit_id
        FROM at_only at
      )
      SELECT
        COUNT(*) FILTER (WHERE matched_jobber_visit_id IS NOT NULL) AS salvageable,
        COUNT(*) FILTER (WHERE matched_jobber_visit_id IS NULL) AS phantom
      FROM matches;
    `);
    console.log(`Window ±${window}d: salvageable=${r[0].salvageable}, phantom=${r[0].phantom}`);
  }

  // Use ±2d window for the breakdown
  console.log('\n=== Salvageable AT-only visits — by year (window=±2d) ===');
  console.table(await q(`
    WITH at_only AS (
      SELECT v.id, v.client_id, v.visit_date FROM visits v
      WHERE EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='airtable')
        AND NOT EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber')
    ),
    salvageable AS (
      SELECT at.id, at.visit_date FROM at_only at
      WHERE EXISTS (
        SELECT 1 FROM visits jv
        WHERE jv.client_id = at.client_id
          AND ABS(jv.visit_date - at.visit_date) <= 2
          AND EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=jv.id AND source_system='jobber')
      )
    )
    SELECT EXTRACT(YEAR FROM visit_date)::int AS year, COUNT(*) AS n
    FROM salvageable GROUP BY year ORDER BY year;
  `));

  console.log('\n=== Phantom (unsalvageable) AT-only visits — by year (window=±2d) ===');
  console.table(await q(`
    WITH at_only AS (
      SELECT v.id, v.client_id, v.visit_date FROM visits v
      WHERE EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='airtable')
        AND NOT EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber')
    ),
    phantom AS (
      SELECT at.id, at.visit_date FROM at_only at
      WHERE NOT EXISTS (
        SELECT 1 FROM visits jv
        WHERE jv.client_id = at.client_id
          AND ABS(jv.visit_date - at.visit_date) <= 2
          AND EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=jv.id AND source_system='jobber')
      )
    )
    SELECT EXTRACT(YEAR FROM visit_date)::int AS year, COUNT(*) AS n
    FROM phantom GROUP BY year ORDER BY year;
  `));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
