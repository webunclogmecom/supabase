// Apply yannick_sandbox_cleanup_2026_05_05.sql to Sandbox.
// Drops the 8 review/bonus columns from visits, replaces the view with the
// Prod-compatible definition (no v.* fallback), and migrates any remaining
// canonical-column data into app_visit_reviews first.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const fs = require('fs'); const path = require('path'); const https = require('https');

const SB = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const sql = fs.readFileSync(path.resolve(__dirname, '../migrations/yannick_sandbox_cleanup_2026_05_05.sql'), 'utf8');

async function pg(query) {
  for (let i = 0; i < 3; i++) {
    const r = await new Promise((res, rej) => {
      const req = https.request({
        hostname: 'api.supabase.com',
        path: `/v1/projects/${SB}/database/query`,
        method: 'POST',
        headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }
      }, x => { let b = ''; x.on('data', d => b += d); x.on('end', () => res({ status: x.statusCode, body: b })); });
      req.on('error', rej);
      req.write(JSON.stringify({ query }));
      req.end();
    });
    if (r.status < 300) return JSON.parse(r.body);
    if (r.status >= 500 || r.status === 429) {
      await new Promise(rs => setTimeout(rs, 4000 * (i + 1))); continue;
    }
    throw new Error(`PG ${r.status}: ${r.body.slice(0, 600)}`);
  }
  throw new Error('5xx exhausted');
}

(async () => {
  console.log('=== PRE-FLIGHT (Sandbox) ===');
  const pre = await pg(`
    SELECT 'app_visit_reviews' AS t, COUNT(*)::int AS n FROM app_visit_reviews UNION ALL
    SELECT 'app_shift_reviews',     COUNT(*)::int    FROM app_shift_reviews UNION ALL
    SELECT 'visits',                COUNT(*)::int    FROM visits UNION ALL
    SELECT 'visits w/ review_status col', (SELECT COUNT(*)::int FROM information_schema.columns
      WHERE table_schema='public' AND table_name='visits' AND column_name='review_status')
  `);
  for (const r of pre) console.log(`  ${r.t.padEnd(36)} ${r.n}`);

  console.log('\n=== APPLYING CLEANUP MIGRATION ===');
  await pg(sql);
  console.log('  ✓ migration applied');

  console.log('\n=== POST-FLIGHT (Sandbox) ===');
  const post = await pg(`
    SELECT 'app_visit_reviews rows' AS t, (SELECT COUNT(*)::int FROM app_visit_reviews) AS n UNION ALL
    SELECT 'app_shift_reviews rows',      (SELECT COUNT(*)::int FROM app_shift_reviews) UNION ALL
    SELECT 'visits column count',         (SELECT COUNT(*)::int FROM information_schema.columns WHERE table_schema='public' AND table_name='visits') UNION ALL
    SELECT 'review_status column exists?',(SELECT COUNT(*)::int FROM information_schema.columns WHERE table_schema='public' AND table_name='visits' AND column_name='review_status') UNION ALL
    SELECT 'visits_with_review row count',(SELECT COUNT(*)::int FROM visits_with_review)
  `);
  for (const r of post) console.log(`  ${r.t.padEnd(36)} ${r.n}`);

  // Confirm the visit-1610 + visit-1799 reads still work via the view
  const verify = await pg(`
    SELECT id, review_status, bonus_status, bonus_denial_note
    FROM visits_with_review
    WHERE id IN (1610, 1799)
    ORDER BY id;
  `);
  console.log('\nVerify smoke-test rows still readable via view:');
  for (const v of verify) console.log(`  ${JSON.stringify(v)}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
