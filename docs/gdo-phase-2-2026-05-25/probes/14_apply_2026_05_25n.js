// Apply Phase 2c migration 2026-05-25n. Mirrors 11_apply_2026_05_25m.js.
const https = require('https');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../../.env') });

const PAT = process.env.SUPABASE_PAT;
const PROD = 'wbasvhvvismukaqdnouk';
const SQL_PATH = path.resolve(__dirname, '../../migrations/2026-05-25n_gdo_phase_2c_applies.sql');

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
  if (!PAT) { console.error('FATAL: SUPABASE_PAT not set'); process.exit(1); }
  if (!fs.existsSync(SQL_PATH)) { console.error('FATAL: migration not found at', SQL_PATH); process.exit(1); }
  const sql = fs.readFileSync(SQL_PATH, 'utf8');
  console.log('=== Applying 2026-05-25n ===');
  console.log('SQL length:', sql.length, 'chars · Target:', PROD, '\n');

  console.log('--- PRE-STATE ---');
  console.log(JSON.stringify((await pg(`
    SELECT
      (SELECT COUNT(*)::int FROM public.gdos WHERE status='ACTIVE') AS active_count,
      (SELECT COUNT(*)::int FROM public.gdos WHERE status='INACTIVE') AS inactive_count,
      (SELECT COUNT(*)::int FROM public.gdos WHERE max_frequency_days IS NOT NULL) AS with_max_freq,
      (SELECT COUNT(*)::int FROM public.gdos WHERE status='ACTIVE' AND permit_expiration <> '2026-12-31') AS active_non_current_exp;
  `)).body, null, 2));

  console.log('\n--- APPLY ---');
  const result = await pg(sql);
  console.log('HTTP status:', result.status);
  console.log('Body:', JSON.stringify(result.body, null, 2));
  if (result.status !== 200 && result.status !== 201) {
    console.error('NON-2xx — migration likely failed. STOP and inspect.');
    process.exit(1);
  }

  console.log('\n--- POST-STATE ---');
  console.log(JSON.stringify((await pg(`
    SELECT
      (SELECT COUNT(*)::int FROM public.gdos WHERE status='ACTIVE') AS active_count,
      (SELECT COUNT(*)::int FROM public.gdos WHERE status='INACTIVE') AS inactive_count,
      (SELECT COUNT(*)::int FROM public.gdos WHERE max_frequency_days IS NOT NULL) AS with_max_freq,
      (SELECT COUNT(*)::int FROM public.gdos WHERE status='ACTIVE' AND permit_expiration <> '2026-12-31') AS active_non_current_exp;
  `)).body, null, 2));

  console.log('\n--- Audit ---');
  console.log(JSON.stringify((await pg(`
    SELECT app_source, operation, COUNT(*)::int AS n
    FROM audit.logs
    WHERE table_name='gdos' AND changed_at > now() - interval '5 minutes'
    GROUP BY app_source, operation ORDER BY app_source, operation;
  `)).body, null, 2));

  console.log('\n=== DONE ===');
})().catch(e => { console.error('FATAL', e); process.exit(1); });
