// Apply migration 2026-05-25l_gdo_phase_2a_sample_applies.sql to Prod
//
// Reads the SQL file and POSTs the whole transaction to the Supabase
// Management API. The migration is wrapped in BEGIN/COMMIT and every UPDATE
// is idempotent (filters on current state).
//
// SAFETY
//   - Migration is idempotent — re-running is a no-op.
//   - Every UPDATE is a fixed-state mutation (no DROPs, no schema changes).
//   - Demotions use status='INACTIVE', never hard-delete (CLAUDE.md Rule 6).
//   - Audit trigger on public.gdos generates app_source='sql' rows.

const https = require('https');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../../.env') });

const PAT = process.env.SUPABASE_PAT;
const PROD = 'wbasvhvvismukaqdnouk';
const SQL_PATH = path.resolve(
  __dirname,
  '../../migrations/2026-05-25l_gdo_phase_2a_sample_applies.sql'
);

function pg(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request(
      {
        hostname: 'api.supabase.com',
        path: `/v1/projects/${PROD}/database/query`,
        method: 'POST',
        headers: {
          Authorization: `Bearer ${PAT}`,
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(body),
        },
      },
      r => {
        let d = '';
        r.on('data', c => (d += c));
        r.on('end', () => {
          try { res({ status: r.statusCode, body: JSON.parse(d) }); }
          catch (_) { res({ status: r.statusCode, body: d }); }
        });
      }
    );
    req.on('error', rej);
    req.write(body);
    req.end();
  });
}

(async () => {
  if (!PAT) {
    console.error('FATAL: SUPABASE_PAT not set in .env');
    process.exit(1);
  }
  if (!fs.existsSync(SQL_PATH)) {
    console.error('FATAL: migration not found at', SQL_PATH);
    process.exit(1);
  }
  const sql = fs.readFileSync(SQL_PATH, 'utf8');
  console.log('=== Applying 2026-05-25l ===');
  console.log('SQL length:', sql.length, 'chars');
  console.log('Target:', PROD);
  console.log('');

  // Capture pre-state for sanity report
  console.log('--- PRE-STATE (counts that will change) ---');
  const pre = await pg(`
    SELECT
      (SELECT COUNT(*)::int FROM public.gdos WHERE status='ACTIVE') AS active_count,
      (SELECT COUNT(*)::int FROM public.gdos
         WHERE status='ACTIVE' AND permit_expiration < '2026-01-01') AS stale_exp_active,
      (SELECT COUNT(*)::int FROM public.gdos WHERE max_frequency_days IS NOT NULL) AS with_max_freq,
      (SELECT COUNT(*)::int FROM public.gdos WHERE location_label IS NOT NULL) AS with_label;
  `);
  console.log(JSON.stringify(pre.body, null, 2));

  // Apply
  console.log('');
  console.log('--- APPLY ---');
  const result = await pg(sql);
  console.log('HTTP status:', result.status);
  console.log('Response body:', JSON.stringify(result.body, null, 2));

  if (result.status !== 200 && result.status !== 201) {
    console.error('NON-2xx STATUS — migration likely failed; STOP and inspect.');
    process.exit(1);
  }

  // Post-state
  console.log('');
  console.log('--- POST-STATE ---');
  const post = await pg(`
    SELECT
      (SELECT COUNT(*)::int FROM public.gdos WHERE status='ACTIVE') AS active_count,
      (SELECT COUNT(*)::int FROM public.gdos
         WHERE status='ACTIVE' AND permit_expiration < '2026-01-01') AS stale_exp_active,
      (SELECT COUNT(*)::int FROM public.gdos WHERE max_frequency_days IS NOT NULL) AS with_max_freq,
      (SELECT COUNT(*)::int FROM public.gdos WHERE location_label IS NOT NULL) AS with_label;
  `);
  console.log(JSON.stringify(post.body, null, 2));

  console.log('');
  console.log('=== DONE ===');
  console.log('Next: node docs/gdo-phase-2-2026-05-25/probes/07_verify_2026_05_25l.js');
})().catch(e => { console.error('FATAL', e); process.exit(1); });
