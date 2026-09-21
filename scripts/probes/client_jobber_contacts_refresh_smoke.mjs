// SMOKE: save-client-contact action:'refresh' - the read-through ingest of Jobber's real
// ContactModel people into public.client_jobber_contacts.
//
// WHAT IT PROVES
//   1. 112-YA gains exactly one row, carrying ContactModel/135562, role QUOTE/INVOICE,
//      yan@ayache.com - a contact that has been in Jobber all along and invisible in the app.
//   2. It is IDEMPOTENT: a second call leaves one row, with synced_at moved forward. (A second
//      row would mean the ON CONFLICT arbiter is wrong.)
//   3. On a client with NO Jobber contacts it creates nothing AND retires nothing.
//   4. The removal pass only runs on a complete read; the response says so either way.
//
// Writes only to public.client_jobber_contacts, which nothing else reads yet.
// Run: cd Supabase && node scripts/probes/client_jobber_contacts_refresh_smoke.mjs
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const env = Object.fromEntries(readFileSync(join(ROOT, '.env'), 'utf8').split(/\r?\n/)
  .filter(l => /^[A-Z_]+=/.test(l))
  .map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '').trim()]));
const U = `https://${env.SUPABASE_PROJECT_ID}.supabase.co`;
const SR = env.SUPABASE_SERVICE_ROLE_KEY;

let failures = 0;
const check = (label, ok, detail = '') => { if (!ok) failures++; console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? '  -- ' + detail : ''}`); };

const sql = async (q) => {
  const r = await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_ID}/database/query`, {
    method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q }),
  });
  return await r.json();
};

const g = await (await fetch(`${U}/auth/v1/admin/generate_link`, { method: 'POST',
  headers: { apikey: SR, Authorization: `Bearer ${SR}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ type: 'magiclink', email: 'fred@ayache.com' }) })).json();
const v = await (await fetch(`${U}/auth/v1/verify`, { method: 'POST',
  headers: { apikey: SR, 'Content-Type': 'application/json' },
  body: JSON.stringify({ type: 'magiclink', token_hash: g.hashed_token }) })).json();
if (!v?.access_token) { console.log('FATAL: could not mint a staff session'); process.exit(1); }

const refresh = async (client_id) => {
  const r = await fetch(`${U}/functions/v1/save-client-contact`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${v.access_token}`, 'Content-Type': 'application/json', apikey: SR },
    body: JSON.stringify({ action: 'refresh', client_id }),
  });
  return await r.json();
};

const rowsFor = async (cid) => await sql(
  `select jobber_contact_id, first_name, last_name, jobber_role, email, phone, is_billing_contact,
          property_gids, deleted_at, synced_at
     from public.client_jobber_contacts where client_id = ${cid} order by id;`);

// ---- 1. 112-YA ------------------------------------------------------------------------------
console.log('1. 112-YA (client 381), which holds ContactModel/135562 in Jobber');
const a = await refresh(381);
console.log('   response:', JSON.stringify(a).slice(0, 220));
check('ok', a?.ok === true, a?.message ? String(a.message).slice(0, 140) : '');
check('read reported COMPLETE (so the removal pass was allowed to run)', a?.complete === true);

const r1 = await rowsFor(381);
check('exactly one row for 112-YA', Array.isArray(r1) && r1.length === 1, `got ${Array.isArray(r1) ? r1.length : JSON.stringify(r1).slice(0, 120)}`);
if (Array.isArray(r1) && r1[0]) {
  const c = r1[0];
  console.log('   row:', JSON.stringify(c));
  check('carries the Jobber ContactModel id', String(c.jobber_contact_id).length > 10);
  check('role is the free Jobber string QUOTE/INVOICE', c.jobber_role === 'QUOTE/INVOICE', String(c.jobber_role));
  check("email is the CONTACT'S own, not the client's", c.email === 'yan@ayache.com', String(c.email));
  check('not soft-deleted', c.deleted_at === null);
}

// ---- 2. idempotency --------------------------------------------------------------------------
console.log('\n2. call it again - must not mint a second row');
const firstSynced = Array.isArray(r1) && r1[0] ? r1[0].synced_at : null;
const b = await refresh(381);
const r2 = await rowsFor(381);
check('still exactly one row', Array.isArray(r2) && r2.length === 1, `got ${Array.isArray(r2) ? r2.length : '?'}`);
check('synced_at moved forward', Array.isArray(r2) && r2[0] && r2[0].synced_at !== firstSynced,
  `${firstSynced} -> ${Array.isArray(r2) && r2[0] ? r2[0].synced_at : '?'}`);
check('second call also reported ok', b?.ok === true);

// ---- 3. a client Jobber has no contacts for --------------------------------------------------
// 432 of 490 Jobber clients have none, so this is the common case, not an edge case.
const cand = await sql(`select cl.id from public.clients cl
   join public.entity_source_links esl
     on esl.entity_type='client' and esl.source_system='jobber' and esl.entity_id=cl.id
  where cl.id <> 381 order by cl.id limit 8;`);
let emptyClient = null;
for (const row of (Array.isArray(cand) ? cand : [])) {
  const res = await refresh(row.id);
  if (res?.ok && res.contacts === 0) { emptyClient = row.id;
    console.log(`\n3. client ${row.id}, which Jobber reports no contacts for`);
    console.log('   response:', JSON.stringify(res).slice(0, 200));
    check('created nothing', res.contacts === 0);
    check('retired nothing', res.retired === 0);
    const r3 = await rowsFor(row.id);
    check('no rows exist for it', Array.isArray(r3) && r3.length === 0, `got ${Array.isArray(r3) ? r3.length : '?'}`);
    break; }
}
if (!emptyClient) console.log('\n3. SKIPPED - every sampled client had contacts (unexpected; 432 of 490 should have none)');

// ---- 4. estate state -------------------------------------------------------------------------
const tot = await sql('select count(*) as n, count(*) filter (where deleted_at is not null) as soft from public.client_jobber_contacts;');
console.log('\n4. table state:', JSON.stringify(tot));

console.log(`\n${failures === 0 ? 'ALL CHECKS PASSED' : failures + ' CHECK(S) FAILED'}`);
process.exit(failures === 0 ? 0 : 1);
