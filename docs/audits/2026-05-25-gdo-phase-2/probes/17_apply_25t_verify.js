// Apply 25t + verify all 6 view rewires.
const https = require('https');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../../.env') });

const PAT = process.env.SUPABASE_PAT;
const PROD = 'wbasvhvvismukaqdnouk';
const SQL_PATH = path.resolve(__dirname, '../../migrations/2026-05-25t_rewire_views_from_gdos.sql');

function pg(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${PROD}/database/query`,
      method: 'POST',
      headers: {
        Authorization: `Bearer ${PAT}`,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      },
    }, r => {
      let d = '';
      r.on('data', c => (d += c));
      r.on('end', () => {
        try { res({ status: r.statusCode, body: JSON.parse(d) }); }
        catch (_) { res({ status: r.statusCode, body: d }); }
      });
    });
    req.on('error', rej);
    req.write(body);
    req.end();
  });
}

(async () => {
  const sql = fs.readFileSync(SQL_PATH, 'utf8');
  console.log('=== Applying 2026-05-25t ===');
  const r = await pg(sql);
  console.log('HTTP', r.status, JSON.stringify(r.body).slice(0, 400));
  if (r.status !== 201 && r.status !== 200) process.exit(1);

  console.log('\n--- 1. No view still references sc.permit_* or sc_gt.permit_* ---');
  console.log(JSON.stringify((await pg(`
    SELECT v.schemaname || '.' || v.viewname AS view_name,
           (v.definition ILIKE '%sc.permit_%' OR v.definition ILIKE '%sc_gt.permit_%')::int AS legacy_ref
    FROM pg_views v
    WHERE v.definition ILIKE '%service_configs%' AND v.definition ILIKE '%permit%'
    ORDER BY view_name;
  `)).body, null, 2));

  console.log('\n--- 2. Casa Neos in v_gdo_expiry (should be 3 rows) ---');
  console.log(JSON.stringify((await pg(`
    SELECT permit_number, permit_expiration::text, permit_status
    FROM ops.v_gdo_expiry
    WHERE client_code='009-CN'
    ORDER BY permit_number;
  `)).body, null, 2));

  console.log('\n--- 3. Row count smoke tests ---');
  console.log(JSON.stringify((await pg(`
    SELECT 'customer.clients' AS view_name, COUNT(*)::int AS n FROM customer.clients
    UNION ALL SELECT 'ops.service_configs', COUNT(*)::int FROM ops.service_configs
    UNION ALL SELECT 'ops.v_derm_compliance', COUNT(*)::int FROM ops.v_derm_compliance
    UNION ALL SELECT 'ops.v_gdo_expiry', COUNT(*)::int FROM ops.v_gdo_expiry
    UNION ALL SELECT 'ops.v_route_today', COUNT(*)::int FROM ops.v_route_today
    UNION ALL SELECT 'ops.v_service_due', COUNT(*)::int FROM ops.v_service_due
    ORDER BY view_name;
  `)).body, null, 2));

  console.log('\n--- 4. Casa Neos in customer.clients ---');
  console.log(JSON.stringify((await pg(`
    SELECT name, gdo_permit_url FROM customer.clients WHERE name ILIKE '%Casa Neos%';
  `)).body, null, 2));

  console.log('\n--- 5. v_gdo_expiry: count by permit_status ---');
  console.log(JSON.stringify((await pg(`
    SELECT permit_status, COUNT(*)::int AS n FROM ops.v_gdo_expiry GROUP BY permit_status ORDER BY permit_status;
  `)).body, null, 2));

  console.log('\n--- 6. Compare ops.service_configs permit_* to public.service_configs.permit_* (sample) ---');
  console.log(JSON.stringify((await pg(`
    SELECT
      (SELECT COUNT(*)::int FROM public.service_configs WHERE permit_number IS NOT NULL) AS legacy_permit_count,
      (SELECT COUNT(DISTINCT client_id)::int FROM public.gdos WHERE status='ACTIVE') AS canonical_clients_with_active_gdo,
      (SELECT COUNT(*)::int FROM ops.service_configs WHERE permit_number IS NOT NULL) AS ops_view_permit_count;
  `)).body, null, 2));

  console.log('\n=== DONE ===');
})().catch(e => { console.error('FATAL', e); process.exit(1); });
