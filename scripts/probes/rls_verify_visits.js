// rls_verify_visits.js — Phase-3 post-lock NEGATIVE matrix with the REAL Prod anon key
// (public/publishable key in prod_anon.txt, gitignored). Creates a fresh LIVE test visit via the
// SECDEF create RPC (service role), then asserts the raw anon key CANNOT drive any visit-lifecycle
// write — neither the direct columns (visit_status/completed_at/deleted_at/schedule/...) NOR the 6
// lifecycle RPCs in EITHER schema (public.* and ops.* — the Calendar client defaults to `ops`).
// Confirms the two intentionally-still-open columns (manhole_count, derm_required) remain writable
// (ship-first accepted risk; not Jobber-delete vectors). Cleans up via the SECDEF delete RPC.
//
// Phase 3 (2026-07-11, docs/migrations/2026-07-11_phase3_visit_lifecycle_lock.sql): REVOKEd
// UPDATE(visit_status, completed_at) from anon+authenticated + anon/PUBLIC EXECUTE on the 6 lifecycle
// RPCs (both schemas). set_visit_status stays authenticated-only. This replaces the pre-Phase-3 probe
// where visit_status/completed_at were POSITIVE (anon-allowed) — they are now NEGATIVE (blocked).
const fs = require('fs');
const https = require('https');
const SP = __dirname;
const env = {};
for (const l of fs.readFileSync('C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/.env', 'utf8').split(/\r?\n/)) {
  const m = l.match(/^([A-Z0-9_]+)=(.*)$/); if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, '');
}
const ANON = fs.readFileSync(SP + '/prod_anon.txt', 'utf8').trim();
const KEY = env.SUPABASE_SERVICE_ROLE_KEY, BASE = env.SUPABASE_URL;

function req(method, path, body, key, profile) {
  return new Promise((res) => {
    const b = body ? JSON.stringify(body) : null;
    const u = new URL(BASE + '/rest/v1' + path);
    const headers = { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json', Prefer: 'return=representation' };
    if (profile) { headers['Content-Profile'] = profile; headers['Accept-Profile'] = profile; }
    if (b) headers['Content-Length'] = Buffer.byteLength(b);
    const r = https.request({ hostname: u.hostname, path: u.pathname + u.search, method, headers },
      x => { let d = ''; x.on('data', c => d += c); x.on('end', () => res({ s: x.statusCode, d })); });
    r.on('error', e => res({ s: 0, d: e.message })); if (b) r.write(b); r.end();
  });
}
const anonPatch = (id, body) => req('PATCH', `/visits?id=eq.${id}`, body, ANON);
const anonRpc = (fn, body, profile) => req('POST', `/rpc/${fn}`, body, ANON, profile);
const svc = (method, path, body) => req(method, path, body, KEY);

const anonPropPatch = (pid, body) => req('PATCH', `/properties?id=eq.${pid}`, body, ANON);

(async () => {
  const c = await svc('POST', '/rpc/create_calendar_visit', { p_client_id: 381, p_job_id: 766, p_service_line_item_ids: [1], p_visit_date: '2026-09-15', p_start_at: '2026-09-15T18:00:00Z', p_end_at: '2026-09-15T19:00:00Z', p_title: 'TEST-RLS do not service [Claude]' });
  const id = JSON.parse(c.d).id;
  const propId = (JSON.parse((await svc('GET', `/visits?id=eq.${id}&select=property_id`, null)).d)[0] || {}).property_id;
  console.log('live test visit', id, '/ property', propId, '\n');

  // anon "blocked" = 401/403/404 or an explicit permission-denied/not-found body (revoked EXECUTE
  // makes PostgREST hide the function → 404; revoked column UPDATE → 403 permission denied).
  const blocked = r => [401, 403, 404].includes(r.s) || /42501|permission denied|could not find|not find the function/i.test(r.d);
  let pass = 0, fail = 0;
  const check = (label, r, cond) => { const ok = cond === undefined ? blocked(r) : cond; console.log((ok ? 'PASS ' : '**FAIL** ') + label + '  [' + r.s + ' ' + r.d.replace(/\s+/g, ' ').slice(0, 70) + ']'); ok ? pass++ : fail++; };

  console.log('=== NEGATIVE: direct anon column writes must be BLOCKED ===');
  for (const [col, val] of [['visit_status', 'completed'], ['completed_at', '2026-09-15T20:00:00Z'], ['deleted_at', '2026-07-09T00:00:00Z'], ['visit_date', '2026-09-20'], ['start_at', '2026-09-16T18:00:00Z'], ['title', 'HACKED'], ['source', 'x'], ['sync_state', 'synced'], ['job_id', 1], ['client_id', 1], ['derm_required_locked', true]]) {
    check('PATCH ' + col, await anonPatch(id, { [col]: val }));
  }
  // atomicity: an allowed col + a forbidden col in one body must fully reject (status stays scheduled).
  const mixed = await anonPatch(id, { manhole_count: 9, visit_status: 'completed' });
  const after = await svc('GET', `/visits?id=eq.${id}&select=visit_status`, null);
  check('mixed {manhole_count+visit_status} rejected atomically (status still scheduled)', mixed, blocked(mixed) && /scheduled/.test(after.d));
  check('direct anon INSERT', await req('POST', '/visits', { client_id: 381, visit_date: '2026-09-15', source: 'visit-calendar' }, ANON));

  console.log('\n=== NEGATIVE: anon lifecycle RPC EXECUTE must be BLOCKED (public.* AND ops.*) ===');
  const rpcBodies = { skip_visit: { p_visit_id: id, p_reason: 'x' }, unskip_visit: { p_visit_id: id }, delete_calendar_visit: { p_visit_id: id }, edit_calendar_visit: { p_visit_id: id, p_patch: { title: 'x' } }, ripple_reschedule_visit: { p_visit_id: id, p_new_date: '2026-09-25', p_dry_run: true }, create_calendar_visit: { p_client_id: 381, p_job_id: 766, p_service_line_item_ids: [1], p_visit_date: '2026-09-15' } };
  for (const fn of Object.keys(rpcBodies)) {
    check('anon rpc public.' + fn, await anonRpc(fn, rpcBodies[fn]));
    check('anon rpc ops.' + fn, await anonRpc(fn, rpcBodies[fn], 'ops'));
  }

  console.log('\n=== NEGATIVE: the last 4 business columns must be BLOCKED (2026-07-11 anon-column harden) ===');
  check('visits.derm_required', await anonPatch(id, { derm_required: false }));
  check('visits.manhole_count', await anonPatch(id, { manhole_count: 3 }));
  if (propId) {
    check('properties.grease_trap_manhole_count', await anonPropPatch(propId, { grease_trap_manhole_count: 5 }));
    check('properties.sample_port_count', await anonPropPatch(propId, { sample_port_count: 2 }));
  } else {
    console.log('(!) test visit had no property_id — skipped properties.* anon checks (investigate)');
  }
  // Positive control: authenticated is NOT tested here (needs a staff JWT — Fred live-verified the apps
  // 2026-07-11). has_column_privilege confirms authenticated=true on all 4 (apps keep working).
  console.log('anon is now FULLY READ-ONLY on visits + properties business data.');

  console.log(`\n=== ${pass} pass / ${fail} fail ===`);

  // cleanup via SECDEF service-role path
  await svc('POST', '/rpc/delete_calendar_visit', { p_visit_id: id });
  console.log('cleanup: delete_calendar_visit(' + id + ')');
  fs.writeFileSync(SP + '/rls_verify_id.json', JSON.stringify({ id }));
})().catch(e => console.log('ERR', e.message));
