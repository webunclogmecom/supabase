// Apply the same client_cleanup_2026_04_30.sql to Sandbox.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const fs = require('fs');
const path = require('path');

const SANDBOX_PROJECT_ID = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

function q(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${SANDBOX_PROJECT_ID}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>r.statusCode<300?res(JSON.parse(d)):rej(new Error(`${r.statusCode}: ${d.slice(0,800)}`))); });
    req.on('error', rej); req.write(body); req.end();
  });
}

(async () => {
  console.log(`Sandbox project: ${SANDBOX_PROJECT_ID}\n`);
  console.log('=== BEFORE ===');
  console.table(await q(`
    SELECT 'codes_active' AS metric, COUNT(*) AS n FROM clients WHERE status='ACTIVE' AND client_code IS NOT NULL
    UNION ALL SELECT 'codes_active_null', COUNT(*) FROM clients WHERE status='ACTIVE' AND client_code IS NULL
    UNION ALL SELECT 'dup_pairs_active', COUNT(*) FROM clients WHERE id IN (436,437,444) AND status='ACTIVE';
  `));

  const sql = fs.readFileSync(path.resolve(__dirname, '../migrations/client_cleanup_2026_04_30.sql'), 'utf8');
  console.log('\n=== Running migration ===');
  await q(sql);
  console.log('  ✓ committed');

  console.log('\n=== AFTER ===');
  console.table(await q(`
    SELECT 'codes_active_with' AS metric, COUNT(*) AS n FROM clients WHERE status='ACTIVE' AND client_code IS NOT NULL
    UNION ALL SELECT 'codes_active_null', COUNT(*) FROM clients WHERE status='ACTIVE' AND client_code IS NULL
    UNION ALL SELECT '777-YA inactive', COUNT(*) FROM clients WHERE id=47 AND status='INACTIVE'
    UNION ALL SELECT '436_inactive', COUNT(*) FROM clients WHERE id=436 AND status='INACTIVE'
    UNION ALL SELECT '437_inactive', COUNT(*) FROM clients WHERE id=437 AND status='INACTIVE'
    UNION ALL SELECT '444_inactive', COUNT(*) FROM clients WHERE id=444 AND status='INACTIVE';
  `));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
