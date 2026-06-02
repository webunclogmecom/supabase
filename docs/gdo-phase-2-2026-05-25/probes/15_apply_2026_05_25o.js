// Apply migration 2026-05-25o (Phase 2c deferrals). Same pattern as 11/14.
const https = require('https');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../../.env') });

const PAT = process.env.SUPABASE_PAT;
const PROD = 'wbasvhvvismukaqdnouk';
const SQL_PATH = path.resolve(__dirname, '../../migrations/2026-05-25o_gdo_phase_2c_deferrals.sql');

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
  console.log('=== Applying 2026-05-25o ===');
  console.log('SQL length:', sql.length, '\n');

  console.log('--- PRE ---');
  console.log(JSON.stringify((await pg(`
    SELECT
      (SELECT COUNT(*)::int FROM public.gdos WHERE status='ACTIVE') AS active,
      (SELECT COUNT(*)::int FROM public.gdos WHERE status='INACTIVE') AS inactive,
      (SELECT COUNT(*)::int FROM public.gdos WHERE max_frequency_days IS NOT NULL) AS with_freq;
  `)).body, null, 2));

  const r = await pg(sql);
  console.log('HTTP:', r.status, 'body:', JSON.stringify(r.body));
  if (r.status !== 201 && r.status !== 200) { console.error('FAIL'); process.exit(1); }

  console.log('\n--- POST ---');
  console.log(JSON.stringify((await pg(`
    SELECT
      (SELECT COUNT(*)::int FROM public.gdos WHERE status='ACTIVE') AS active,
      (SELECT COUNT(*)::int FROM public.gdos WHERE status='INACTIVE') AS inactive,
      (SELECT COUNT(*)::int FROM public.gdos WHERE max_frequency_days IS NOT NULL) AS with_freq;
  `)).body, null, 2));

  console.log('\n--- Spot checks ---');
  console.log(JSON.stringify((await pg(`
    SELECT id, gdo_number, status, max_frequency_days FROM public.gdos
    WHERE id IN (4, 26, 27, 39, 46, 57, 62, 68, 73)
    ORDER BY id;
  `)).body, null, 2));

  console.log('\n--- Audit ---');
  console.log(JSON.stringify((await pg(`
    SELECT app_source, operation, COUNT(*)::int AS n FROM audit.logs
    WHERE table_name='gdos' AND changed_at > now() - interval '3 minutes'
    GROUP BY app_source, operation;
  `)).body, null, 2));
})().catch(e => { console.error('FATAL', e); process.exit(1); });
