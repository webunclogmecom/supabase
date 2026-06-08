// migrate_admin_reviews_to_prod.js [--execute]
// One-time copy of the Admin Review review/bonus rows from Sandbox #1
// (public.app_visit_reviews / public.app_shift_reviews) to Prod canonical
// (public.visit_reviews / public.shift_reviews). Maps external_visit_id->visit_id,
// external_employee_id->employee_id; preserves every other column incl. timestamps.
// Re-runnable: ON CONFLICT DO NOTHING. Reads SUPABASE_PAT from Supabase/.env.
const https = require('https');
const fs = require('fs');
const path = require('path');
const SANDBOX = 'ubtlwpcyntelgbykdatn';
const PROD = 'wbasvhvvismukaqdnouk';
function readEnv(k) { const p = path.resolve(__dirname, '../../.env'); const l = fs.readFileSync(p, 'utf8').split(/\r?\n/).find(x => x.startsWith(k + '=')); return l ? l.slice(k.length + 1).trim() : null; }
const PAT = readEnv('SUPABASE_PAT');
function query(ref, sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({ hostname: 'api.supabase.com', path: '/v1/projects/' + ref + '/database/query', method: 'POST',
      headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } },
      r => { let d = ''; r.on('data', c => d += c); r.on('end', () => { if (r.statusCode >= 300) return rej(new Error('HTTP ' + r.statusCode + ' ' + d)); try { res(JSON.parse(d)) } catch (e) { res(d) } }); });
    req.on('error', rej); req.write(body); req.end();
  });
}
const lit = v => (v === null || v === undefined) ? 'NULL' : (typeof v === 'number' ? String(v) : "'" + String(v).replace(/'/g, "''") + "'");

(async () => {
  const avr = await query(SANDBOX, 'SELECT * FROM public.app_visit_reviews ORDER BY external_visit_id;');
  const asr = await query(SANDBOX, 'SELECT * FROM public.app_shift_reviews ORDER BY external_employee_id, shift_date;');
  console.log(`Sandbox source: app_visit_reviews=${avr.length}, app_shift_reviews=${asr.length}`);

  const vr = avr.map(r => `(${lit(r.external_visit_id)},${lit(r.review_status)},${lit(r.reviewed_at)},${lit(r.reviewed_by)},${lit(r.bonus_status)},${lit(r.bonus_decided_at)},${lit(r.bonus_decided_by)},${lit(r.bonus_denial_note)},${lit(r.quality_flag_note)},${lit(r.created_at)},${lit(r.updated_at)})`);
  const sr = asr.map(r => `(${lit(r.external_employee_id)},${lit(r.shift_date)},${lit(r.review_status)},${lit(r.reviewed_at)},${lit(r.reviewed_by)},${lit(r.bonus_status)},${lit(r.bonus_decided_at)},${lit(r.bonus_decided_by)},${lit(r.bonus_denial_note)},${lit(r.shift_quality_note)},${lit(r.created_at)},${lit(r.updated_at)})`);

  let sql = '';
  if (vr.length) sql += `INSERT INTO public.visit_reviews (visit_id,review_status,reviewed_at,reviewed_by,bonus_status,bonus_decided_at,bonus_decided_by,bonus_denial_note,quality_flag_note,created_at,updated_at) VALUES ${vr.join(',')} ON CONFLICT (visit_id) DO NOTHING;`;
  if (sr.length) sql += `\nINSERT INTO public.shift_reviews (employee_id,shift_date,review_status,reviewed_at,reviewed_by,bonus_status,bonus_decided_at,bonus_decided_by,bonus_denial_note,shift_quality_note,created_at,updated_at) VALUES ${sr.join(',')} ON CONFLICT (employee_id,shift_date) DO NOTHING;`;

  if (process.argv.includes('--execute')) {
    await query(PROD, sql);
    const c = await query(PROD, 'SELECT (SELECT count(*) FROM public.visit_reviews) AS visit_reviews, (SELECT count(*) FROM public.shift_reviews) AS shift_reviews;');
    console.log('Prod after copy:', JSON.stringify(c[0]));
  } else {
    console.log('DRY RUN (pass --execute to apply).\n' + sql);
  }
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
