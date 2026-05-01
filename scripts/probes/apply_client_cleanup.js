// Apply client_cleanup_2026_04_30.sql to PRODUCTION as one transaction.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const fs = require('fs');
const path = require('path');

const PROJECT_ID = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

function q(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${PROJECT_ID}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>r.statusCode<300?res(JSON.parse(d)):rej(new Error(`${r.statusCode}: ${d.slice(0,800)}`))); });
    req.on('error', rej); req.write(body); req.end();
  });
}

(async () => {
  console.log('=== BEFORE state ===');
  console.table(await q(`
    SELECT 'codes_active' AS metric, COUNT(*) AS n FROM clients WHERE status='ACTIVE' AND client_code IS NOT NULL
    UNION ALL SELECT 'codes_active_null', COUNT(*) FROM clients WHERE status='ACTIVE' AND client_code IS NULL
    UNION ALL SELECT '777-YA status', NULL FROM clients WHERE id=47 AND status='ACTIVE'
    UNION ALL SELECT 'dup_pairs_active', COUNT(*) FROM clients WHERE id IN (436,437,444) AND status='ACTIVE';
  `));

  console.log('\n=== Running migration (single transaction) ===');
  const sql = fs.readFileSync(path.resolve(__dirname, '../migrations/client_cleanup_2026_04_30.sql'), 'utf8');
  await q(sql);
  console.log('  ✓ migration committed');

  console.log('\n=== AFTER state ===');
  console.table(await q(`
    SELECT 'codes_active_with' AS metric, COUNT(*) AS n FROM clients WHERE status='ACTIVE' AND client_code IS NOT NULL
    UNION ALL SELECT 'codes_active_null', COUNT(*) FROM clients WHERE status='ACTIVE' AND client_code IS NULL
    UNION ALL SELECT '777-YA inactive?', COUNT(*) FROM clients WHERE id=47 AND status='INACTIVE'
    UNION ALL SELECT 'dup_pair_436_inactive?', COUNT(*) FROM clients WHERE id=436 AND status='INACTIVE'
    UNION ALL SELECT 'dup_pair_437_inactive?', COUNT(*) FROM clients WHERE id=437 AND status='INACTIVE'
    UNION ALL SELECT 'dup_pair_444_inactive?', COUNT(*) FROM clients WHERE id=444 AND status='INACTIVE'
    UNION ALL SELECT 'invoices_total', COUNT(*) FROM invoices
    UNION ALL SELECT 'tower41_invoices_376', COUNT(*) FROM invoices WHERE client_id=376
    UNION ALL SELECT 'tower41_invoices_444', COUNT(*) FROM invoices WHERE client_id=444
    UNION ALL SELECT 'le_specialita_353_jobs', COUNT(*) FROM jobs WHERE client_id=353
    UNION ALL SELECT 'le_specialita_353_visits', COUNT(*) FROM visits WHERE client_id=353
    UNION ALL SELECT 'yasu_354_jobs', COUNT(*) FROM jobs WHERE client_id=354
    UNION ALL SELECT 'yasu_354_visits', COUNT(*) FROM visits WHERE client_id=354
    UNION ALL SELECT 'tower41_376_jobs', COUNT(*) FROM jobs WHERE client_id=376
    UNION ALL SELECT 'tower41_376_visits', COUNT(*) FROM visits WHERE client_id=376;
  `));

  console.log('\n=== Spot-check Yan\'s carrot express now has code ===');
  console.table(await q(`
    SELECT id, client_code, name, status FROM clients
    WHERE name ILIKE '%carrot express%' ORDER BY name;
  `));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
