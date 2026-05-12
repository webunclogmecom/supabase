// Apply the gidless-clients cleanup migration to a target DB.
// Plus import the 1 missing Jobber client (Carne en Vara) via webhook replay.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const target = (process.argv.find(a => a.startsWith('--target=')) || '--target=main').split('=')[1];
const PROJECT = target === 'sandbox' ? process.env.SANDBOX_SUPABASE_PROJECT_ID : process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const SUPABASE_URL = target === 'sandbox' ? process.env.SANDBOX_SUPABASE_URL : process.env.SUPABASE_URL;
const JOBBER_CLIENT_SECRET = process.env.JOBBER_CLIENT_SECRET;

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      let d = ''; r.on('data', c => d += c);
      r.on('end', () => res({ status: r.statusCode, body: d }));
    });
    req.on('error', rej);
    if (body) req.write(body);
    req.end();
  });
}

async function pg(sql) {
  const body = JSON.stringify({ query: sql });
  const r = await http({
    hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
  }, body);
  if (r.status >= 300) throw new Error(`DB ${r.status}: ${r.body.slice(0,800)}`);
  return JSON.parse(r.body);
}

(async () => {
  console.log(`Target: ${target} (${PROJECT})\n`);

  console.log('=== BEFORE ===');
  console.table(await pg(`
    SELECT 'clients_total' AS metric, COUNT(*) AS n FROM clients
    UNION ALL SELECT 'gidless_clients', COUNT(*) FROM clients c WHERE NOT EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='client' AND entity_id=c.id AND source_system='jobber');
  `));

  console.log('\n=== Running merge + delete migration ===');
  const sql = fs.readFileSync(path.resolve(__dirname, '../migrations/cleanup_gidless_clients_2026_05_01.sql'), 'utf8');
  await pg(sql);
  console.log('  ✓ committed');

  console.log('\n=== AFTER ===');
  console.table(await pg(`
    SELECT 'clients_total' AS metric, COUNT(*) AS n FROM clients
    UNION ALL SELECT 'gidless_clients', COUNT(*) FROM clients c WHERE NOT EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='client' AND entity_id=c.id AND source_system='jobber')
    UNION ALL SELECT 'duplicate_codes_remaining', (SELECT COUNT(*) FROM (SELECT client_code FROM clients WHERE client_code IS NOT NULL GROUP BY client_code HAVING COUNT(*) > 1) x);
  `));

  console.log('\n=== Phase A: Import Carne en Vara via webhook-jobber replay (Production only) ===');
  if (target === 'sandbox') {
    console.log('  Skipped on sandbox (sandbox replay would need Jobber pull cache fresh data; daily refresh handles parity)');
  } else if (!JOBBER_CLIENT_SECRET) {
    console.log('  Skipped — JOBBER_CLIENT_SECRET not in env');
  } else {
    // Find the missing Jobber GID — the one we identified in the audit
    const missingGid = 'Z2lkOi8vSm9iYmVyL0NsaWVudC8xNDA4MDU3NTM=';  // from clients_diff.log
    const numericId = Buffer.from(missingGid, 'base64').toString().split('/').pop();
    const payload = JSON.stringify({ topic: 'CLIENT_UPDATE', webHookEvent: { itemId: numericId, occurredAt: new Date().toISOString() } });
    const sig = crypto.createHmac('sha256', JOBBER_CLIENT_SECRET).update(payload).digest('base64');
    const supabaseHost = SUPABASE_URL.replace(/^https?:\/\//, '').replace(/\/$/, '');
    const r = await http({
      hostname: supabaseHost, path: '/functions/v1/webhook-jobber', method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${process.env.SUPABASE_SERVICE_ROLE_KEY}`,
        'x-jobber-hmac-sha256': sig,
        'Content-Length': Buffer.byteLength(payload),
      },
    }, payload);
    console.log(`  HTTP ${r.status}: ${r.body.slice(0, 200)}`);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
