// Verify migration 2026-05-25l applied correctly.
// Runs the 7 checks documented in the migration header.

const https = require('https');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../../.env') });

const PAT = process.env.SUPABASE_PAT;
const PROD = 'wbasvhvvismukaqdnouk';

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
          try { res(JSON.parse(d)); } catch (_) { res(d); }
        });
      }
    );
    req.on('error', rej);
    req.write(body);
    req.end();
  });
}

(async () => {
  console.log('=== VERIFY 2026-05-25l ===\n');

  console.log('--- 1. Casa Neos (ids 63/64/65) ---');
  console.log(await pg(`
    SELECT id, gdo_number, location_label, max_frequency_days,
           permit_expiration::text, status
    FROM public.gdos
    WHERE property_id = 42
    ORDER BY id;
  `));
  console.log('Expected: 63 KITCHENS 60 2026-12-31, 64 BARS 90 2026-12-31, 65 LOUNGE 30 2026-12-31');

  console.log('\n--- 2. Simple matches ---');
  console.log(await pg(`
    SELECT gdo_number, max_frequency_days, permit_expiration::text
    FROM public.gdos
    WHERE gdo_number IN ('GDO-15328','GDO-10822','GDO-11532')
    ORDER BY gdo_number;
  `));
  console.log('Expected: GDO-10822 30, GDO-11532 30, GDO-15328 90; all 2026-12-31');

  console.log('\n--- 3. 4 mismatched demoted ---');
  console.log(await pg(`
    SELECT gdo_number, status,
           split_part(notes, '[2026-05-25 Phase 2a]', 2) AS phase2a_note
    FROM public.gdos
    WHERE gdo_number IN ('GDO-01179','GDO-00376','GDO-14336','GDO-01759')
    ORDER BY gdo_number;
  `));
  console.log('Expected: all status=INACTIVE');

  console.log('\n--- 4. ACTIVE count (expect 131; was 135 - 4 demotes) ---');
  console.log(await pg(`
    SELECT COUNT(*) FILTER (WHERE status='ACTIVE')::int AS active_count,
           COUNT(*) FILTER (WHERE status='INACTIVE')::int AS inactive_count,
           COUNT(*)::int AS total
    FROM public.gdos;
  `));

  console.log('\n--- 5. No ACTIVE rows with stale expirations ---');
  console.log(await pg(`
    SELECT COUNT(*)::int AS stale_active_count
    FROM public.gdos
    WHERE status='ACTIVE' AND permit_expiration < '2026-01-01';
  `));
  console.log('Expected: 0');

  console.log('\n--- 6. Spot-check: 15 random ACTIVE rows ---');
  console.log(await pg(`
    SELECT g.gdo_number, g.permit_expiration::text, g.max_frequency_days,
           c.client_code
    FROM public.gdos g
    JOIN public.clients c ON c.id = g.client_id
    WHERE g.status='ACTIVE'
    ORDER BY random()
    LIMIT 15;
  `));
  console.log('Expected: every permit_expiration is 2026-12-31');

  console.log('\n--- 7. Audit rows generated in last 5 min ---');
  console.log(await pg(`
    SELECT app_source,
           COUNT(*) FILTER (WHERE action='UPDATE')::int AS updates,
           COUNT(*) FILTER (WHERE action='INSERT')::int AS inserts,
           COUNT(*) FILTER (WHERE action='DELETE')::int AS deletes
    FROM audit.logs
    WHERE table_name='gdos'
      AND occurred_at > now() - interval '5 minutes'
    GROUP BY app_source;
  `));
  console.log('Expected: app_source=sql with at least 10 UPDATEs (typically 120+)');

  console.log('\n=== DONE ===');
})().catch(e => { console.error('FATAL', e); process.exit(1); });
