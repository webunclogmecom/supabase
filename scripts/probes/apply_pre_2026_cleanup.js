// Apply delete_pre_2026_visits.sql to a target DB.
// Usage: node ... [--target=main|sandbox]
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const fs = require('fs');
const path = require('path');

const target = (process.argv.find(a => a.startsWith('--target=')) || '--target=main').split('=')[1];
const PROJECT = target === 'sandbox' ? process.env.SANDBOX_SUPABASE_PROJECT_ID : process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

function q(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>r.statusCode<300?res(JSON.parse(d)):rej(new Error(`${r.statusCode}: ${d.slice(0,800)}`))); });
    req.on('error', rej); req.write(body); req.end();
  });
}

(async () => {
  console.log(`Target: ${target} (${PROJECT})\n`);

  console.log('=== BEFORE ===');
  console.table(await q(`
    SELECT 'visits_total' AS metric, COUNT(*) AS n FROM visits
    UNION ALL SELECT 'visits_pre_2026', COUNT(*) FROM visits WHERE visit_date < '2026-01-01' OR visit_date IS NULL
    UNION ALL SELECT 'photos_total', COUNT(*) FROM photos
    UNION ALL SELECT 'photo_links_total', COUNT(*) FROM photo_links
    UNION ALL SELECT 'notes_total', COUNT(*) FROM notes
    UNION ALL SELECT 'manifest_visits_total', COUNT(*) FROM manifest_visits
    UNION ALL SELECT 'visit_assignments_total', COUNT(*) FROM visit_assignments
    UNION ALL SELECT 'esl_total', COUNT(*) FROM entity_source_links;
  `));

  const sql = fs.readFileSync(path.resolve(__dirname, '../migrations/delete_pre_2026_visits.sql'), 'utf8');
  console.log('\n=== Running migration (single transaction) ===');
  await q(sql);
  console.log('  ✓ committed');

  console.log('\n=== AFTER ===');
  console.table(await q(`
    SELECT 'visits_total' AS metric, COUNT(*) AS n FROM visits
    UNION ALL SELECT 'visits_pre_2026', COUNT(*) FROM visits WHERE visit_date < '2026-01-01' OR visit_date IS NULL
    UNION ALL SELECT 'photos_total', COUNT(*) FROM photos
    UNION ALL SELECT 'photo_links_total', COUNT(*) FROM photo_links
    UNION ALL SELECT 'notes_total', COUNT(*) FROM notes
    UNION ALL SELECT 'manifest_visits_total', COUNT(*) FROM manifest_visits
    UNION ALL SELECT 'visit_assignments_total', COUNT(*) FROM visit_assignments
    UNION ALL SELECT 'esl_total', COUNT(*) FROM entity_source_links;
  `));

  console.log('\n=== Surviving visits — by year & source ===');
  console.table(await q(`
    SELECT EXTRACT(YEAR FROM visit_date)::int AS year,
      CASE
        WHEN at_links.cnt > 0 AND jb_links.cnt > 0 THEN 'BOTH'
        WHEN jb_links.cnt > 0                      THEN 'jobber'
        WHEN at_links.cnt > 0                      THEN 'airtable_only'
        ELSE 'no_links'
      END AS src,
      COUNT(*) AS n
    FROM visits v
    LEFT JOIN LATERAL (SELECT COUNT(*) AS cnt FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber') jb_links ON true
    LEFT JOIN LATERAL (SELECT COUNT(*) AS cnt FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='airtable') at_links ON true
    GROUP BY year, src ORDER BY year, src;
  `));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
