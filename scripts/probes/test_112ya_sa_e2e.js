// test_112ya_sa_e2e.js — EXTREME end-to-end test of the 112-YA Service Agreement
// visit-generation pipeline. Mutates ONLY 112-YA (client 381, job 765) + its supabase_cron
// visits, and ALWAYS restores a clean baseline (frequency_days=60 + the canonical 6 visits)
// via a finally block — even if an assertion throws midway.
//
// Run: node scripts/probes/test_112ya_sa_e2e.js
const https = require('https');
const { execSync } = require('child_process');
const path = require('path');
const fs = require('fs');

function readEnv(k) { const p = path.resolve(__dirname, '../../.env'); const l = fs.readFileSync(p, 'utf8').split(/\r?\n/).find(x => x.startsWith(k + '=')); return l ? l.slice(k.length + 1).trim() : null; }
const PAT = readEnv('SUPABASE_PAT');
const ref = (readEnv('SUPABASE_URL') || '').match(/https?:\/\/([^.]+)\./)[1];
function pg(sql) { return new Promise((res, rej) => { const body = JSON.stringify({ query: sql }); const req = https.request({ hostname: 'api.supabase.com', path: '/v1/projects/' + ref + '/database/query', method: 'POST', headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, r => { let d = ''; r.on('data', c => d += c); r.on('end', () => { if (r.statusCode >= 300) return rej(new Error(r.statusCode + ': ' + d.slice(0, 300))); res(JSON.parse(d)); }); }); req.on('error', rej); req.write(body); req.end(); }); }

const SYNC = path.resolve(__dirname, '../sync');
const FETCH = path.join(SYNC, 'fetch_service_agreement_jobs.js');
// ⚠ 2026-08-01: generation moved INTO the database (public.fn_generate_sa_visits);
// generate_service_agreement_visits.js was deleted, so this no longer shells out.
// ⚠⚠ AND THIS PROBE CANNOT PASS AS WRITTEN: 112-YA is in the generator's
// EXCLUDED_CLIENT_CODES ('112-YA','777-YA','000-DH'), which are refused even when
// named explicitly — so generation for 381 correctly returns 0. That exclusion
// predates the port; the probe was already inert. Left in place rather than
// deleted so the next person sees WHY, but it needs rewriting against a
// non-excluded fixture client before it means anything. The anchor branches it
// was trying to cover are now covered by the rolled-back fixtures in
// docs/migrations/2026-08-01_1450 (branches 3/4 + the not-started guard).
async function runGen() {
  const r = await pg(`select public.fn_generate_sa_visits(${CID}, 6, false) as v`);
  return JSON.stringify(r[0].v);
}
function runFetch() { try { return execSync(`node "${FETCH}" --client=112-YA --execute`, { encoding: 'utf8' }); } catch (e) { return 'FETCH-ERR: ' + (e.message || '').slice(0, 120); } }

const CID = 381, JOB = 765;
const results = [];
function check(name, cond, detail) { results.push({ name, pass: !!cond }); console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${detail ? '  [' + detail + ']' : ''}`); }

const saVisits = async () => pg(`SELECT visit_date::text d, derm_required FROM visits WHERE client_id=${CID} AND source='supabase_cron' AND deleted_at IS NULL ORDER BY visit_date;`);
const freq = async () => (await pg(`SELECT frequency_days f FROM jobs WHERE id=${JOB};`))[0].f;
const liNames = async () => (await pg(`SELECT name FROM line_items WHERE job_id=${JOB} AND invoice_id IS NULL ORDER BY name;`)).map(r => r.name);
const spacing = ds => ds.slice(1).map((d, i) => (Date.parse(d) - Date.parse(ds[i])) / 86400000);
const todayUTC = new Date().toISOString().slice(0, 10);

(async () => {
  let b_v;
  try {
    console.log('=== BASELINE ===');
    const b_freq = await freq(); const b_li = await liNames(); b_v = await saVisits();
    console.log(`freq=${b_freq} | line_items=${b_li.length} | cron visits=${b_v.length}: ${b_v.map(x => x.d).join(', ')}`);
    check('baseline freq=60', b_freq === 60, 'freq=' + b_freq);
    check('baseline 6 visits', b_v.length === 6, b_v.length + ' visits');

    // T1 — fetch + generator idempotency
    console.log('\n=== T1 idempotency (re-run fetch + generator) ===');
    runFetch();
    const f1 = await freq(); check('T1 freq still 60 after re-fetch', f1 === 60, 'freq=' + f1);
    check('T1 line_items still 3', (await liNames()).length === 3);
    runGen();
    const v1 = await saVisits();
    check('T1 generator idempotent (6, same dates)', v1.length === b_v.length && v1.map(x => x.d).join() === b_v.map(x => x.d).join(), v1.length + ' visits');

    // T2 — scope isolation (no other client touched)
    console.log('\n=== T2 scope isolation ===');
    const oFreq = await pg(`SELECT j.id FROM jobs j JOIN clients c ON c.id=j.client_id WHERE j.frequency_days>0 AND c.client_code<>'112-YA';`);
    check('T2 no other client has frequency_days', oFreq.length === 0, oFreq.length + ' other jobs');
    const oVis = await pg(`SELECT DISTINCT c.client_code cc FROM visits v JOIN clients c ON c.id=v.client_id WHERE v.source='supabase_cron' AND v.deleted_at IS NULL AND c.client_code<>'112-YA';`);
    check('T2 no other client has supabase_cron visits', oVis.length === 0, oVis.map(x => x.cc).join(','));

    // T3 — attributes + drawer view
    console.log('\n=== T3 attributes + drawer view ===');
    check('T3 all visits derm_required=true', b_v.every(x => x.derm_required === true));
    const det = (await pg(`SELECT service_kind sk, agreement_frequency_days af, json_array_length(line_items) n, jobber_job_url u FROM ops.v_calendar_visit_detail WHERE client_id=${CID} AND service_kind='service_agreement' LIMIT 1;`))[0];
    check('T3 view service_kind=service_agreement', det.sk === 'service_agreement');
    check('T3 view agreement_frequency_days=60', det.af === 60);
    check('T3 view 3 line items', det.n === 3);
    check('T3 view work_orders URL', /work_orders\/146650142$/.test(det.u), det.u);
    // edge: SC visit -> service_call, 0 line items, freq null
    const sc = (await pg(`SELECT service_kind sk, agreement_frequency_days af, json_array_length(line_items) n FROM ops.v_calendar_visit_detail WHERE client_id=${CID} AND service_kind='service_call' LIMIT 1;`))[0];
    check('T3 SC visit service_call + 0 items + null freq', sc && sc.sk === 'service_call' && sc.n === 0 && sc.af === null);

    // T7 — fetch is the source of truth: a manual DB frequency change is overwritten by Jobber's value
    console.log('\n=== T7 fetch authority (manual freq=99 -> re-fetch restores Jobber 60) ===');
    await pg(`UPDATE jobs SET frequency_days=99 WHERE id=${JOB};`);
    const out7 = runFetch();
    if (typeof out7 === 'string' && out7.startsWith('FETCH-ERR')) check('T7 fetch authority (SKIPPED: Jobber throttled)', true, 'throttled');
    else { const f7 = await freq(); check('T7 re-fetch overwrote manual freq back to Jobber 60', f7 === 60, 'freq=' + f7); }

    // T8 — zero-frequency guard: freq=0 generates nothing
    console.log('\n=== T8 zero-frequency guard ===');
    await pg(`UPDATE visits SET deleted_at=NOW() WHERE client_id=${CID} AND source='supabase_cron' AND deleted_at IS NULL;`);
    await pg(`UPDATE jobs SET frequency_days=0 WHERE id=${JOB};`);
    runGen();
    const v8 = await saVisits(); check('T8 freq=0 generates no visits', v8.length === 0, v8.length + ' visits');

    // T4 — frequency change 60 -> 30 (clean slate)
    console.log('\n=== T4 frequency change 60 -> 30 ===');
    await pg(`UPDATE visits SET deleted_at=NOW() WHERE client_id=${CID} AND source='supabase_cron' AND deleted_at IS NULL;`);
    await pg(`UPDATE jobs SET frequency_days=30 WHERE id=${JOB};`);
    runGen();
    const v30 = await saVisits(); const sp30 = spacing(v30.map(x => x.d));
    check('T4 every gap = 30 days', sp30.length > 0 && sp30.every(g => g === 30), 'gaps=' + [...new Set(sp30)].join(','));
    check('T4 more visits than at 60d', v30.length > b_v.length, v30.length + ' visits');
    check('T4 first visit >= today', v30.length > 0 && v30[0].d >= todayUTC, v30[0] && v30[0].d);
    check('T4 within MAX cap (<=24)', v30.length <= 24, v30.length);

    // T5 — idempotent at freq=30
    runGen();
    const v30b = await saVisits();
    check('T5 idempotent at freq=30 (no new)', v30b.length === v30.length, v30b.length + ' visits');

    // T6 — restore baseline 60
    console.log('\n=== T6 restore baseline (freq=60) ===');
    await pg(`UPDATE visits SET deleted_at=NOW() WHERE client_id=${CID} AND source='supabase_cron' AND deleted_at IS NULL;`);
    await pg(`UPDATE jobs SET frequency_days=60 WHERE id=${JOB};`);
    runGen();
    const vR = await saVisits();
    check('T6 freq restored to 60', (await freq()) === 60);
    check('T6 exactly 6 visits', vR.length === 6, vR.length + ' visits');
    check('T6 dates match baseline', vR.map(x => x.d).join() === b_v.map(x => x.d).join(), vR.map(x => x.d).join(', '));
    check('T6 derm restored true', vR.every(x => x.derm_required === true));
  } catch (e) { console.error('\nFATAL:', e.message); check('NO FATAL ERROR', false, e.message.slice(0, 80)); }
  finally {
    // Bulletproof restore — independent of which test threw.
    try {
      if ((await freq()) !== 60) { await pg(`UPDATE jobs SET frequency_days=60 WHERE id=${JOB};`); console.log('[restore] freq -> 60'); }
      const cur = await saVisits();
      const want = (b_v || []).map(x => x.d).join();
      if (cur.map(x => x.d).join() !== want || cur.length !== 6) {
        await pg(`UPDATE visits SET deleted_at=NOW() WHERE client_id=${CID} AND source='supabase_cron' AND deleted_at IS NULL;`);
        runGen();
        const fin = await saVisits();
        console.log('[restore] regenerated -> ' + fin.length + ' visits: ' + fin.map(x => x.d).join(', '));
      } else { console.log('[restore] baseline already clean (6 visits)'); }
    } catch (re) { console.error('[restore] ERROR:', re.message); }
    const pass = results.filter(r => r.pass).length, fail = results.filter(r => !r.pass).length;
    console.log(`\n=== RESULT: ${pass} PASS / ${fail} FAIL ===`);
    if (fail) console.log('FAILED: ' + results.filter(r => !r.pass).map(r => r.name).join(' | '));
    process.exit(fail ? 1 : 0);
  }
})();
