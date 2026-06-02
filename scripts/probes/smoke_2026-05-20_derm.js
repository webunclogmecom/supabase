// Smoke test after 2026-05-20 DERM cleanup batch (orphans/hollows/dupes/ghosts +
// gdos table + county backfill + Edge Function prevention guards).
const https = require('https');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const PAT = process.env.SUPABASE_PAT;
const TOKEN = process.env.AIRTABLE_WEBHOOK_TOKEN;
const ref = process.env.SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];

function pg(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({ hostname: 'api.supabase.com', path: '/v1/projects/' + ref + '/database/query', method: 'POST', headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>{ if(r.statusCode>=300) return rej(new Error(r.statusCode+': '+d.slice(0,400))); res(JSON.parse(d)); }); });
    req.on('error', rej); req.write(body); req.end();
  });
}
function ef(payload) {
  return new Promise((res, rej) => {
    const body = JSON.stringify(payload);
    const req = https.request({ hostname: 'wbasvhvvismukaqdnouk.supabase.co', path: '/functions/v1/webhook-airtable', method: 'POST', headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + TOKEN, 'Content-Length': Buffer.byteLength(body) } }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>{ res({status: r.statusCode, body: d}); }); });
    req.on('error', rej); req.write(body); req.end();
  });
}

let pass = 0, fail = 0;
function check(name, cond, detail = '') {
  if (cond) { console.log('  PASS', name); pass++; }
  else      { console.log('  FAIL', name, '-', detail); fail++; }
}

(async () => {
  console.log('A. DB INTEGRITY');
  const dm = await pg(`SELECT
    (SELECT COUNT(*) FROM public.derm_manifests) AS total,
    (SELECT COUNT(*) FROM public.derm_manifests WHERE client_id IS NULL) AS orphans,
    (SELECT COUNT(*) FROM public.derm_manifests dm
       WHERE dm.derm_manifest_url IS NULL AND dm.derm_address_url IS NULL
         AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.manifest_id=dm.id)
         AND (dm.white_manifest_number IS NOT NULL OR dm.yellow_ticket_number IS NOT NULL)) AS ghost_rows,
    (SELECT COUNT(*) FROM public.derm_manifests
       WHERE client_id IS NOT NULL AND white_manifest_number IS NULL AND yellow_ticket_number IS NULL
         AND derm_manifest_url IS NULL AND derm_address_url IS NULL AND dump_ticket_date IS NULL) AS hollow_rows,
    (SELECT COUNT(*) FROM (SELECT client_id, white_manifest_number FROM public.derm_manifests
       WHERE client_id IS NOT NULL AND white_manifest_number IS NOT NULL
       GROUP BY 1,2 HAVING COUNT(*) > 1) x) AS wm_dupes,
    (SELECT COUNT(*) FROM (SELECT client_id, yellow_ticket_number FROM public.derm_manifests
       WHERE client_id IS NOT NULL AND yellow_ticket_number IS NOT NULL
       GROUP BY 1,2 HAVING COUNT(*) > 1) y) AS yt_dupes
    FROM (VALUES (1)) v`);
  check('derm_manifests total = 885', dm[0].total === 885, 'got ' + dm[0].total);
  check('orphans = 1 (id 959 only)', dm[0].orphans === 1, 'got ' + dm[0].orphans);
  check('ghost rows = 0', dm[0].ghost_rows === 0, 'got ' + dm[0].ghost_rows);
  check('hollow rows = 0', dm[0].hollow_rows === 0, 'got ' + dm[0].hollow_rows);
  check('WM dupes = 0', dm[0].wm_dupes === 0, 'got ' + dm[0].wm_dupes);
  check('YT dupes = 0', dm[0].yt_dupes === 0, 'got ' + dm[0].yt_dupes);

  const cons = await pg(`SELECT conname FROM pg_constraint WHERE conrelid='public.derm_manifests'::regclass AND contype='u'`);
  check('UNIQUE constraint client_wm exists', cons.some(c => c.conname === 'derm_manifests_client_wm_unique'));
  check('UNIQUE constraint client_yt exists', cons.some(c => c.conname === 'derm_manifests_client_yt_unique'));

  const gd = await pg(`SELECT COUNT(*) AS total, (SELECT COUNT(*) FROM public.gdos WHERE client_id=369) AS casa_neos FROM public.gdos`);
  check('gdos total = 104', gd[0].total === 104, 'got ' + gd[0].total);
  check('Casa Neos has 3 GDOs', gd[0].casa_neos === 3, 'got ' + gd[0].casa_neos);

  console.log('\nB. derm.visits VIEW');
  const dv = await pg(`SELECT COUNT(*) AS total,
    COUNT(*) FILTER (WHERE has_manifest) AS documented,
    COUNT(*) FILTER (WHERE needs_manifest AND NOT has_manifest) AS missing,
    COUNT(*) FILTER (WHERE NOT needs_manifest) AS not_required,
    COUNT(*) FILTER (WHERE line_items IS NOT NULL) AS with_line_items
    FROM derm.visits`);
  check('derm.visits total > 500', dv[0].total > 500, 'got ' + dv[0].total);
  check('documented > 0', dv[0].documented > 0, 'got ' + dv[0].documented);
  check('line_items aggregation > 400', dv[0].with_line_items > 400, 'got ' + dv[0].with_line_items);
  console.log('   stats:', dv[0]);

  console.log('\nC. PROPERTIES COUNTY');
  const pc = await pg(`SELECT COUNT(*) AS total, COUNT(*) FILTER (WHERE county IS NULL OR county='') AS missing FROM public.properties`);
  check('all properties classified', pc[0].missing === 0, 'still missing: ' + pc[0].missing);

  console.log('\nD. EDGE FUNCTION GUARDS');
  // D1. Empty payload skipped
  const r1 = await ef({ entity: 'derm_manifest', recordId: 'recPROBE_SMOKE_EMPTY', fields: {}, changeType: 'updated' });
  check('empty payload returned 200', r1.status === 200);
  const r1db = await pg(`SELECT COUNT(*) AS c FROM public.entity_source_links WHERE source_id='recPROBE_SMOKE_EMPTY'`);
  check('empty payload did NOT create ESL', Number(r1db[0].c) === 0, 'got ' + r1db[0].c);

  // D2. Hollow (client only) skipped
  const cli = await pg(`SELECT source_id FROM public.entity_source_links WHERE entity_type='client' AND source_system='airtable' LIMIT 1`);
  const r2 = await ef({ entity: 'derm_manifest', recordId: 'recPROBE_SMOKE_HOLLOW', fields: { Client: [cli[0].source_id] }, changeType: 'updated' });
  check('hollow payload returned 200', r2.status === 200);
  const r2db = await pg(`SELECT COUNT(*) AS c FROM public.entity_source_links WHERE source_id='recPROBE_SMOKE_HOLLOW'`);
  check('hollow payload did NOT create ESL', Number(r2db[0].c) === 0, 'got ' + r2db[0].c);

  // D3. Real payload (client + WM# + dump) → should land
  const r3 = await ef({ entity: 'derm_manifest', recordId: 'recPROBE_SMOKE_REAL', fields: { Client: [cli[0].source_id], 'White Manifest #': 'SMOKE-TEST-999999', 'Date Dump Ticket': '2026-05-20' }, changeType: 'updated' });
  check('real payload returned 200', r3.status === 200);
  const r3db = await pg(`SELECT COUNT(*) AS c FROM public.derm_manifests dm JOIN public.entity_source_links esl ON esl.entity_id=dm.id AND esl.entity_type='derm_manifest' WHERE esl.source_id='recPROBE_SMOKE_REAL'`);
  check('real payload created 1 DB row', Number(r3db[0].c) === 1, 'got ' + r3db[0].c);

  // D4. Duplicate (same client + WM#, different AT id) → should route to existing, not insert
  const r4 = await ef({ entity: 'derm_manifest', recordId: 'recPROBE_SMOKE_DUP', fields: { Client: [cli[0].source_id], 'White Manifest #': 'SMOKE-TEST-999999', 'Date Dump Ticket': '2026-05-20' }, changeType: 'updated' });
  check('dup payload returned 200', r4.status === 200);
  const r4db = await pg(`SELECT COUNT(*) AS c FROM public.derm_manifests WHERE white_manifest_number='SMOKE-TEST-999999'`);
  check('dup payload did NOT create 2nd row', Number(r4db[0].c) === 1, 'got ' + r4db[0].c);

  // Cleanup smoke-test rows
  await pg(`DELETE FROM public.entity_source_links WHERE source_id LIKE 'recPROBE_SMOKE_%'`);
  await pg(`DELETE FROM public.derm_manifests WHERE white_manifest_number='SMOKE-TEST-999999'`);

  console.log('\nSUMMARY: pass=' + pass + ' fail=' + fail);
  if (fail > 0) process.exit(1);
})().catch(e => { console.error('ERR:', e.message); process.exit(1); });
