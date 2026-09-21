// SMOKE: save-client-contact action:'edit_jobber_contact' - editing one of Jobber's REAL people.
// This is the path that makes first name / last name / role / email / phone round-trip, which is
// what Fred asked for and what the old mirror row could never do.
//
// Subject: 112-YA ContactModel/135562 only. Every write is reverted and re-read.
// Run: cd Slack && JT=$(./jobber-token.sh) && cd ../Supabase && JT=$JT node scripts/probes/edit_jobber_contact_smoke.mjs
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const env = Object.fromEntries(readFileSync(join(ROOT, '.env'), 'utf8').split(/\r?\n/)
  .filter(l => /^[A-Z_]+=/.test(l))
  .map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '').trim()]));
const U = `https://${env.SUPABASE_PROJECT_ID}.supabase.co`;
const SR = env.SUPABASE_SERVICE_ROLE_KEY;
const JT = (process.env.JT || '').trim();
if (!JT) { console.log('FATAL: set JT=$(./jobber-token.sh)'); process.exit(1); }

const CLIENT_ROW = 381;
const CLIENT_GID = 'Z2lkOi8vSm9iYmVyL0NsaWVudC8xMDY1Njc0MDQ=';
const CONTACT_GID = 'Z2lkOi8vSm9iYmVyL0NvbnRhY3RNb2RlbC8xMzU1NjI=';

let failures = 0;
const check = (l, ok, d = '') => { if (!ok) failures++; console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${l}${d ? '  -- ' + d : ''}`); };

const sql = async (q) => await (await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_ID}/database/query`, {
  method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'Content-Type': 'application/json' },
  body: JSON.stringify({ query: q }) })).json();

const jobber = async (query, variables) => await (await fetch('https://api.getjobber.com/api/graphql', {
  method: 'POST',
  headers: { Authorization: `Bearer ${JT}`, 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16', 'Content-Type': 'application/json' },
  body: JSON.stringify({ query, variables }) })).json();

const Q = `query($id: EncodedId!) { client(id: $id) { contacts(first: 5) { nodes {
  id firstName lastName role emails(first:3){nodes{id address primary}} phones(first:3){nodes{id number primary}} } } } }`;
const readJobber = async () => ((await jobber(Q, { id: CLIENT_GID }))?.data?.client?.contacts?.nodes || [])
  .find(n => n.id === CONTACT_GID);

const g = await (await fetch(`${U}/auth/v1/admin/generate_link`, { method: 'POST',
  headers: { apikey: SR, Authorization: `Bearer ${SR}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ type: 'magiclink', email: 'fred@ayache.com' }) })).json();
const v = await (await fetch(`${U}/auth/v1/verify`, { method: 'POST',
  headers: { apikey: SR, 'Content-Type': 'application/json' },
  body: JSON.stringify({ type: 'magiclink', token_hash: g.hashed_token }) })).json();
if (!v?.access_token) { console.log('FATAL: no staff session'); process.exit(1); }

const callFn = async (body) => await (await fetch(`${U}/functions/v1/save-client-contact`, {
  method: 'POST',
  headers: { Authorization: `Bearer ${v.access_token}`, 'Content-Type': 'application/json', apikey: SR },
  body: JSON.stringify(body) })).json();

// ---- 0. sync our mirror of the contact, and find its row id ----------------------------------
await callFn({ action: 'refresh', client_id: CLIENT_ROW });
const [row0] = await sql(`select id, first_name, last_name, jobber_role, email, phone
   from public.client_jobber_contacts
  where client_id = ${CLIENT_ROW} and jobber_contact_id = '${CONTACT_GID}' and deleted_at is null;`);
if (!row0) { console.log('FATAL: the Jobber contact is not mirrored; run the refresh smoke first.'); process.exit(1); }
const ROW = row0.id;
const jb = await readJobber();
console.log('BASELINE');
console.log(`  ours  : ${row0.first_name} ${row0.last_name} | role ${JSON.stringify(row0.jobber_role)} | ${row0.email} | ${row0.phone}`);
console.log(`  jobber: ${jb.firstName} ${jb.lastName} | role ${JSON.stringify(jb.role)} | ${jb.emails.nodes[0]?.address} | ${jb.phones.nodes[0]?.number}`);
const baseEmailId = jb.emails.nodes[0]?.id;

// ---- 1. a real edit: the four fields the app could never touch --------------------------------
console.log('\n1. edit first name, last name, role and email - the fields the old dialog disabled');
const e1 = await callFn({ action: 'edit_jobber_contact', jobber_contact_row_id: ROW,
  patch: { first_name: 'Yannick', last_name: 'Ayache [TEST]', role: 'QUOTE/INVOICE [TEST]', email: 'yan+smoke@ayache.com' } });
console.log('   response:', JSON.stringify(e1).slice(0, 200));
check('reported ok', e1?.ok === true, e1?.message ? String(e1.message).slice(0, 140) : '');

const j1 = await readJobber();   // INDEPENDENT re-read, not the function's word
check('last name landed IN JOBBER', j1?.lastName === 'Ayache [TEST]', String(j1?.lastName));
check('role landed IN JOBBER', j1?.role === 'QUOTE/INVOICE [TEST]', String(j1?.role));
check('email landed IN JOBBER', j1?.emails?.nodes?.[0]?.address === 'yan+smoke@ayache.com', String(j1?.emails?.nodes?.[0]?.address));
check('edited in place - same Email id, no new object', j1?.emails?.nodes?.[0]?.id === baseEmailId);

const [r1] = await sql(`select first_name, last_name, jobber_role, email from public.client_jobber_contacts where id = ${ROW};`);
check('our row followed Jobber', r1?.jobber_role === 'QUOTE/INVOICE [TEST]' && r1?.email === 'yan+smoke@ayache.com',
  JSON.stringify(r1));

// ---- 2. the drift guard: our stored value deliberately disagrees with Jobber ------------------
console.log('\n2. drift guard - make our row disagree with Jobber, then try to save');
await sql(`update public.client_jobber_contacts set email = 'stale@example.com' where id = ${ROW};`);
const e2 = await callFn({ action: 'edit_jobber_contact', jobber_contact_row_id: ROW, patch: { email: 'someoneelse@example.com' } });
check('refused with stale_view', e2?.ok === false && e2?.code === 'stale_view', `code=${e2?.code}`);
check('and said what disagreed', Array.isArray(e2?.drifted) && e2.drifted.length > 0, JSON.stringify(e2?.drifted ?? []).slice(0, 140));
const j2 = await readJobber();
check('Jobber was NOT touched by the refused save', j2?.emails?.nodes?.[0]?.address === 'yan+smoke@ayache.com',
  String(j2?.emails?.nodes?.[0]?.address));

// ---- 3. revert everything ---------------------------------------------------------------------
console.log('\n3. revert');
await callFn({ action: 'refresh', client_id: CLIENT_ROW });   // clears the stale value we injected
const e3 = await callFn({ action: 'edit_jobber_contact', jobber_contact_row_id: ROW,
  patch: { first_name: jb.firstName ?? '', last_name: jb.lastName ?? '', role: jb.role ?? '', email: jb.emails.nodes[0]?.address ?? '' } });
check('revert accepted', e3?.ok === true, e3?.message ? String(e3.message).slice(0, 140) : '');
const j3 = await readJobber();
check('JOBBER back to the exact baseline',
  j3?.firstName === jb.firstName && j3?.lastName === jb.lastName && j3?.role === jb.role
  && j3?.emails?.nodes?.[0]?.address === jb.emails.nodes[0]?.address,
  `${j3?.firstName} ${j3?.lastName} | ${j3?.role} | ${j3?.emails?.nodes?.[0]?.address}`);
check('and still the same Email id', j3?.emails?.nodes?.[0]?.id === baseEmailId);

console.log(`\n${failures === 0 ? 'ALL CHECKS PASSED' : failures + ' CHECK(S) FAILED'}`);
process.exit(failures === 0 ? 0 : 1);
