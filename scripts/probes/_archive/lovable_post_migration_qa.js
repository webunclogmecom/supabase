// End-to-end QA from our side mirroring Lovable's post-refresh-qa.mjs.
// Runs both via Mgmt API (privileged) and via anon REST (Lovable's actual
// runtime) to confirm RLS lets the right reads through.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const SB = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const SB_HOST = `${SB}.supabase.co`;
const ANON = process.env.SANDBOX_SUPABASE_ANON_KEY;
const PAT = process.env.SUPABASE_PAT;

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); if (body) req.write(body); req.end();
  });
}
async function pg(sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${SB}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 200)}`);
  return JSON.parse(r.body);
}
async function rest(path) {
  const r = await http({
    hostname: SB_HOST,
    path: '/rest/v1/' + path,
    method: 'GET',
    headers: { apikey: ANON, Authorization: `Bearer ${ANON}` }
  });
  return { status: r.status, body: r.body ? JSON.parse(r.body) : null };
}

const passes = [];
const failures = [];
function check(name, ok, detail) {
  (ok ? passes : failures).push(name);
  console.log(`  ${ok ? '✓' : '✗'} ${name}${ok ? '' : '  → ' + JSON.stringify(detail).slice(0, 200)}`);
}

(async () => {
  console.log('=== Schema state (priv) ===');
  const cols = await pg(`SELECT COUNT(*)::int AS n FROM information_schema.columns WHERE table_schema='public' AND table_name='visits'`);
  check('Sandbox.visits is 20 columns (8 review/bonus dropped)', cols[0].n === 20, cols[0]);

  const droppedCheck = await pg(`SELECT COUNT(*)::int AS n FROM information_schema.columns WHERE table_schema='public' AND table_name='visits' AND column_name IN ('review_status','reviewed_at','reviewed_by','bonus_status','bonus_decided_at','bonus_decided_by','bonus_denial_note','quality_flag_note')`);
  check('All 8 review/bonus columns gone from visits', droppedCheck[0].n === 0, droppedCheck[0]);

  const viewDef = await pg(`SELECT pg_get_viewdef('public.visits_with_review'::regclass, true) AS def`);
  const vDef = viewDef[0].def;
  const has3Way = /COALESCE\([^,]+,\s*v\./.test(vDef);
  check('visits_with_review is Prod-style (no 3-way COALESCE)', !has3Way, has3Way ? 'still uses v.* fallback' : 'OK');

  const trig = await pg(`SELECT COUNT(*)::int AS n FROM information_schema.triggers WHERE event_object_schema='public' AND event_object_table='visits' AND trigger_name='visits_validate_review_status_trg'`);
  check('Old validate trigger removed', trig[0].n === 0, trig[0]);

  const checks = await pg(`SELECT COUNT(*)::int AS n FROM pg_constraint WHERE contype='c' AND conrelid IN ('public.app_visit_reviews'::regclass, 'public.app_shift_reviews'::regclass)`);
  check('CHECK constraints on app_* tables (4 expected)', checks[0].n === 4, checks[0]);

  console.log('\n=== Data state (priv) ===');
  const rows = await pg(`SELECT 'app_visit_reviews' AS t, COUNT(*)::int AS n FROM app_visit_reviews UNION ALL SELECT 'app_shift_reviews', COUNT(*)::int FROM app_shift_reviews`);
  for (const r of rows) console.log(`  ${r.t}: ${r.n} rows`);
  check('app_visit_reviews has 2+ rows', rows[0].n >= 2, rows[0]);
  check('app_shift_reviews has 2+ rows', rows[1].n >= 2, rows[1]);

  console.log('\n=== Lovable-runtime simulation (anon REST) ===');

  if (!ANON) {
    console.log('  ⚠ SANDBOX_SUPABASE_ANON_KEY missing in .env — skipping anon checks');
  } else {
    // 1. Visit 1610 — approved/approved
    const r1 = await rest('visits_with_review?select=id,review_status,bonus_status&id=eq.1610');
    const row1 = Array.isArray(r1.body) ? r1.body[0] : null;
    check('anon: visit 1610 = approved/approved', row1 && row1.review_status === 'approved' && row1.bonus_status === 'approved', r1);

    // 2. Visit 1799 — pending/denied "no images"
    const r2 = await rest('visits_with_review?select=id,review_status,bonus_status,bonus_denial_note&id=eq.1799');
    const row2 = Array.isArray(r2.body) ? r2.body[0] : null;
    check('anon: visit 1799 = pending/denied "no images"',
      row2 && row2.review_status === 'pending' && row2.bonus_status === 'denied' && /no images/i.test(row2.bonus_denial_note ?? ''), r2);

    // 3. Pending queue filter
    const r3 = await rest('visits_with_review?select=id&review_status=eq.pending&limit=5');
    check('anon: pending queue queryable via view', r3.status === 200 && Array.isArray(r3.body) && r3.body.length > 0, r3);

    // 4. app_shift_reviews readable
    const r4 = await rest('app_shift_reviews?select=external_employee_id,shift_date,review_status,bonus_status');
    check('anon: app_shift_reviews readable + non-empty', r4.status === 200 && Array.isArray(r4.body) && r4.body.length >= 1, r4);

    // 5. Embeds resolve through view (clients + properties)
    const r5 = await rest('visits_with_review?select=id,clients(id,name),properties(id)&id=eq.1610');
    const row5 = Array.isArray(r5.body) ? r5.body[0] : null;
    check('anon: PostgREST embeds resolve through view',
      row5 && row5.clients !== undefined && row5.properties !== undefined, r5);

    // 6. app_visit_reviews readable
    const r6 = await rest('app_visit_reviews?select=external_visit_id,review_status,bonus_status');
    check('anon: app_visit_reviews readable + non-empty', r6.status === 200 && Array.isArray(r6.body) && r6.body.length >= 1, r6);

    // 7. Anon write capability — try a no-op upsert that re-asserts existing visit 1610 state
    const writeBody = JSON.stringify({
      external_visit_id: 1610,
      review_status: 'approved',
      bonus_status: 'approved'
    });
    const r7 = await new Promise((res, rej) => {
      const req = https.request({
        hostname: SB_HOST,
        path: '/rest/v1/app_visit_reviews?on_conflict=external_visit_id',
        method: 'POST',
        headers: {
          apikey: ANON, Authorization: `Bearer ${ANON}`,
          'Content-Type': 'application/json',
          'Prefer': 'resolution=merge-duplicates,return=minimal',
          'Content-Length': Buffer.byteLength(writeBody)
        }
      }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res({ status: x.statusCode, body: b })); });
      req.on('error', rej); req.write(writeBody); req.end();
    });
    check('anon: app_visit_reviews upsert works (no RLS denial)', r7.status >= 200 && r7.status < 300, r7);
  }

  console.log(`\n${passes.length} passed, ${failures.length} failed`);
  if (failures.length) {
    console.log('Failures:');
    for (const f of failures) console.log('  - ' + f);
  }
  process.exit(failures.length === 0 ? 0 : 1);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
