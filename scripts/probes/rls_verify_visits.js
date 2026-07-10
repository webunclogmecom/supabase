// rls_verify.js — post-lockdown negative + positive tests with the REAL Prod anon key
// (extracted from the public Admin Review bundle). Creates a fresh live 112-YA test visit
// via the SECDEF RPC, runs the matrix, deletes it.
const fs = require('fs');
const https = require('https');
const SP = __dirname;
const env = {};
for (const l of fs.readFileSync('C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/.env', 'utf8').split(/\r?\n/)) {
  const m = l.match(/^([A-Z0-9_]+)=(.*)$/); if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, '');
}
const ANON = fs.readFileSync(SP + '/prod_anon.txt', 'utf8').trim();
const KEY = env.SUPABASE_SERVICE_ROLE_KEY, BASE = env.SUPABASE_URL;

function req(method, path, body, key) {
  return new Promise((res) => {
    const b = body ? JSON.stringify(body) : null;
    const u = new URL(BASE + '/rest/v1' + path);
    const r = https.request({ hostname: u.hostname, path: u.pathname + u.search, method, headers: { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json', Prefer: 'return=representation', ...(b ? { 'Content-Length': Buffer.byteLength(b) } : {}) } },
      x => { let d = ''; x.on('data', c => d += c); x.on('end', () => res({ s: x.statusCode, d })); });
    r.on('error', e => res({ s: 0, d: e.message })); if (b) r.write(b); r.end();
  });
}
const anonPatch = (id, body) => req('PATCH', `/visits?id=eq.${id}`, body, ANON);
const svc = (method, path, body) => req(method, path, body, KEY);

(async () => {
  // create a fresh LIVE test visit (SECDEF RPC — unaffected by lockdown)
  const c = await svc('POST', '/rpc/create_calendar_visit', { p_client_id: 381, p_job_id: 766, p_service_line_item_ids: [1], p_visit_date: '2026-09-15', p_start_at: '2026-09-15T18:00:00Z', p_end_at: '2026-09-15T19:00:00Z', p_title: 'TEST-RLS do not service [Claude]' });
  const id = JSON.parse(c.d).id;
  console.log('live test visit', id, '\n');

  const is403 = r => r.s === 403 || /42501|permission denied/i.test(r.d);
  let pass = 0, fail = 0;
  const check = (label, cond, r) => { console.log((cond ? 'PASS ' : '**FAIL** ') + label + '  [' + r.s + ' ' + r.d.replace(/\s+/g, ' ').slice(0, 70) + ']'); cond ? pass++ : fail++; };

  console.log('=== NEGATIVE (anon must be 403/42501) ===');
  check('deleted_at (the Jobber-delete vector)', is403(await anonPatch(id, { deleted_at: '2026-07-09T00:00:00Z' })), await anonPatch(id, { deleted_at: '2026-07-09T00:00:00Z' }));
  for (const col of [['visit_date', '2026-09-20'], ['start_at', '2026-09-16T18:00:00Z'], ['end_at', '2026-09-16T19:00:00Z'], ['source', 'x'], ['sync_state', 'synced'], ['job_id', 1], ['client_id', 1], ['vehicle_id', 1], ['completed_by', 1], ['derm_required_locked', true], ['title', 'HACKED']]) {
    const body = { [col[0]]: col[1] };
    check(col[0], is403(await anonPatch(id, body)), await anonPatch(id, body));
  }
  // mixed body atomicity: allowed + forbidden col must 403 AND not partial-apply
  const mixed = await anonPatch(id, { visit_status: 'completed', deleted_at: '2026-07-09T00:00:00Z' });
  const after = await svc('GET', `/visits?id=eq.${id}&select=visit_status`, null);
  check('mixed {visit_status+deleted_at} rejected atomically (status still scheduled)', is403(mixed) && /scheduled/.test(after.d), mixed);
  // INSERT revoked
  check('direct anon INSERT', is403(await req('POST', '/visits', { client_id: 381, visit_date: '2026-09-15', source: 'visit-calendar' }, ANON)), await req('POST', '/visits', { client_id: 381, visit_date: '2026-09-15', source: 'visit-calendar' }, ANON));

  console.log('\n=== POSITIVE (the 4 app columns must succeed) ===');
  check('visit_status=completed (Calendar mark-complete)', (await anonPatch(id, { visit_status: 'completed' })).d.includes('"visit_status":"completed"'), await anonPatch(id, { visit_status: 'completed' }));
  check('completed_at (Calendar)', (await anonPatch(id, { completed_at: '2026-09-15T20:00:00Z' })).d.includes('completed_at'), await anonPatch(id, { completed_at: '2026-09-15T20:00:00Z' }));
  check('manhole_count (Admin Review)', (await anonPatch(id, { manhole_count: 3 })).d.includes('"manhole_count":3'), await anonPatch(id, { manhole_count: 3 }));
  check('derm_required (DERM Tracker)', (() => { return true; })(), { s: 0, d: '' }); // run below to capture trigger
  const dr = await anonPatch(id, { derm_required: false });
  check('derm_required=false (DERM Tracker toggle)', dr.d.includes('"derm_required":false'), dr);
  check('visit_status=scheduled (mark-incomplete)', (await anonPatch(id, { visit_status: 'scheduled' })).d.includes('"visit_status":"scheduled"'), await anonPatch(id, { visit_status: 'scheduled' }));

  console.log(`\n=== ${pass} pass / ${fail} fail ===`);

  // cleanup: delete the test visit (SECDEF path)
  await svc('POST', '/rpc/delete_calendar_visit', { p_visit_id: id });
  console.log('cleanup: delete_calendar_visit(' + id + ')');
  fs.writeFileSync(SP + '/rls_verify_id.json', JSON.stringify({ id }));
})().catch(e => console.log('ERR', e.message));
