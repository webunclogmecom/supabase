// Apply migration 2026-05-25m to Prod.
//
// Mirrors probes/06_apply_2026_05_25l.js but for the Phase 2b migration.
// Reads SQL file, POSTs the full transaction to Supabase Management API,
// reports pre/post state.
//
// SAFETY
//   - Every UPDATE is idempotent (filters on current state)
//   - DEMOTEs use status='INACTIVE' (CLAUDE.md Rule 6, no hard deletes)
//   - WRONG_GDO_NUMBER in-place UPDATEs are safe — confirmed no conflicts
//     with existing gdo_numbers (the 2 conflicting cases were re-routed to
//     DEMOTE in section 6 of the SQL)

const https = require('https');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../../.env') });

const PAT = process.env.SUPABASE_PAT;
const PROD = 'wbasvhvvismukaqdnouk';
const SQL_PATH = path.resolve(
  __dirname,
  '../../migrations/2026-05-25m_gdo_phase_2b_applies.sql'
);

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
  console.log('=== Applying 2026-05-25m ===');
  console.log('SQL length:', sql.length, 'chars');
  console.log('Target:', PROD, '\n');

  console.log('--- PRE-STATE ---');
  const pre = await pg(`
    SELECT
      (SELECT COUNT(*)::int FROM public.gdos WHERE status='ACTIVE') AS active_count,
      (SELECT COUNT(*)::int FROM public.gdos WHERE status='INACTIVE') AS inactive_count,
      (SELECT COUNT(*)::int FROM public.gdos WHERE max_frequency_days IS NOT NULL) AS with_max_freq,
      (SELECT COUNT(*)::int FROM public.gdos
        WHERE status='ACTIVE' AND permit_expiration IS NULL) AS null_exp_active;
  `);
  console.log(JSON.stringify(pre.body, null, 2));

  console.log('\n--- APPLY ---');
  const result = await pg(sql);
  console.log('HTTP status:', result.status);
  console.log('Body:', JSON.stringify(result.body, null, 2));
  if (result.status !== 200 && result.status !== 201) {
    console.error('NON-2xx — migration likely failed. STOP and inspect.');
    process.exit(1);
  }

  console.log('\n--- POST-STATE ---');
  const post = await pg(`
    SELECT
      (SELECT COUNT(*)::int FROM public.gdos WHERE status='ACTIVE') AS active_count,
      (SELECT COUNT(*)::int FROM public.gdos WHERE status='INACTIVE') AS inactive_count,
      (SELECT COUNT(*)::int FROM public.gdos WHERE max_frequency_days IS NOT NULL) AS with_max_freq,
      (SELECT COUNT(*)::int FROM public.gdos
        WHERE status='ACTIVE' AND permit_expiration IS NULL) AS null_exp_active;
  `);
  console.log(JSON.stringify(post.body, null, 2));

  console.log('\n--- WRONG_GDO_NUMBER in-place verification ---');
  const renamed = await pg(`
    SELECT id, gdo_number FROM public.gdos
    WHERE id IN (133, 125, 59, 7, 44)
    ORDER BY id;
  `);
  console.log(JSON.stringify(renamed.body, null, 2));
  console.log('Expected: 7=GDO-14681, 44=GDO-10891, 59=GDO-14769, 125=GDO-11708, 133=GDO-16086');

  console.log('\n--- Conflict-demote verification (Kosh + Nu Real) ---');
  const demoted = await pg(`
    SELECT id, gdo_number, status FROM public.gdos
    WHERE id IN (124, 88) ORDER BY id;
  `);
  console.log(JSON.stringify(demoted.body, null, 2));
  console.log('Expected: both INACTIVE');

  console.log('\n--- Audit row count ---');
  const audit = await pg(`
    SELECT app_source, operation, COUNT(*)::int AS n
    FROM audit.logs
    WHERE table_name='gdos' AND changed_at > now() - interval '5 minutes'
    GROUP BY app_source, operation ORDER BY app_source, operation;
  `);
  console.log(JSON.stringify(audit.body, null, 2));

  console.log('\n=== DONE ===');
})().catch(e => { console.error('FATAL', e); process.exit(1); });
