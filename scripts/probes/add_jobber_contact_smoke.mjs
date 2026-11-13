// SMOKE: save-client-contact action:'add_jobber_contact' (and a property contact through edit_jobber_contact and refresh),
// on 112-YA only. Every contact it adds is deleted again. Plan: Building Apps/Client App/docs/specs/2026-11-13-add-contact-in-jobber-plan.md
// Run: cd Slack && JT=$(./jobber-token.sh) && cd ../Supabase && JT=$JT node scripts/probes/add_jobber_contact_smoke.mjs
//      add --cleanup-only to delete leftovers of a hand test (first name Test, last name starting Smoke) and stop.
// 🛑 A contact with a property lives under property.contacts, NOT client.contacts (measured 2026-11-13), so every read here
//    looks at both lists.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const env = Object.fromEntries(readFileSync(join(ROOT, '.env'), 'utf8').split(/\r?\n/)
  .filter((l) => /^[A-Z_]+=/.test(l))
  .map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '').trim()]));
const U = `https://${env.SUPABASE_PROJECT_ID}.supabase.co`;
const SR = env.SUPABASE_SERVICE_ROLE_KEY;
const JT = (process.env.JT || '').trim();
if (!JT) { console.log('FATAL: set JT=$(./jobber-token.sh)'); process.exit(1); }
const CLIENT_ROW = 381;                                      // 112-YA
const CLIENT_GID = 'Z2lkOi8vSm9iYmVyL0NsaWVudC8xMDY1Njc0MDQ=';

let failures = 0;
const check = (l, ok, d = '') => { if (!ok) failures++; console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${l}${d ? '  -- ' + d : ''}`); };
const sql = async (q) => await (await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_ID}/database/query`, {
  method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'Content-Type': 'application/json' },
  body: JSON.stringify({ query: q }) })).json();
const jobber = async (query, variables) => await (await fetch('https://api.getjobber.com/api/graphql', { method: 'POST',
  headers: { Authorization: `Bearer ${JT}`, 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16', 'Content-Type': 'application/json' },
  body: JSON.stringify({ query, variables }) })).json();
const NODE = `id firstName lastName role isBillingContact receivesReminders receivesFollowUps receivesQuoteFollowUps
  receivesInvoiceFollowUps canAccessClientHub emails(first:3){nodes{address}} properties(first:5){nodes{id}}`;
const READ = `query($id: EncodedId!){ client(id:$id){ contacts(first:25){ nodes{ ${NODE} } }
  properties { id contacts(first:10){ nodes{ ${NODE} } } } } }`;
// every contact on the client, each tagged with where Jobber lists it
const nodes = async () => {
  const c = (await jobber(READ, { id: CLIENT_GID }))?.data?.client;
  return [...(c?.contacts?.nodes || []).map((n) => ({ ...n, listedOn: 'client' })),
    ...(c?.properties || []).flatMap((p) => (p.contacts?.nodes || []).map((n) => ({ ...n, listedOn: p.id })))];
};
const EDIT = `mutation($id: EncodedId!, $input: ClientEditInput!){ clientEdit(clientId:$id, input:$input){ userErrors{ message } } }`;

const g = await (await fetch(`${U}/auth/v1/admin/generate_link`, { method: 'POST',
  headers: { apikey: SR, Authorization: `Bearer ${SR}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ type: 'magiclink', email: 'fred@ayache.com' }) })).json();
const v = await (await fetch(`${U}/auth/v1/verify`, { method: 'POST', headers: { apikey: SR, 'Content-Type': 'application/json' },
  body: JSON.stringify({ type: 'magiclink', token_hash: g.hashed_token }) })).json();
if (!v?.access_token) { console.log('FATAL: no staff session'); process.exit(1); }
const callFn = async (body) => await (await fetch(`${U}/functions/v1/save-client-contact`, { method: 'POST',
  headers: { Authorization: `Bearer ${v.access_token}`, 'Content-Type': 'application/json', apikey: SR },
  body: JSON.stringify(body) })).json();

const cleanup = async (isMine) => {
  for (const n of (await nodes()).filter(isMine)) {
    const d = await jobber(EDIT, { id: CLIENT_GID, input: { contactsToDelete: [n.id] } });
    check(`deleted ${n.firstName} ${n.lastName} in Jobber`, (d?.data?.clientEdit?.userErrors || []).length === 0);
  }
  const r = await callFn({ action: 'refresh', client_id: CLIENT_ROW });   // retires the mirror rows
  check('refresh after cleanup: ok and complete', r.ok === true && r.complete === true, JSON.stringify(r).slice(0, 200));
  check('none left in Jobber', (await nodes()).filter(isMine).length === 0);
};
if (process.argv.includes('--cleanup-only')) {
  await cleanup((n) => n.firstName === 'Test' && /^Smoke/.test(n.lastName || ''));
  process.exit(failures ? 1 : 0);
}

const [prop] = await sql(`select p.id, l.source_id from public.properties p join public.entity_source_links l
  on l.entity_type='property' and l.source_system='jobber' and l.entity_id=p.id
  where p.client_id=${CLIENT_ROW} and p.deleted_at is null and right(l.source_id, 8) <> '_billing' order by p.id limit 1`);
const [other] = await sql(`select p.id from public.properties p where p.client_id <> ${CLIENT_ROW} and p.deleted_at is null order by p.id limit 1`);
if (!prop?.source_id || !other?.id) { console.log('FATAL: fixture lookup failed', JSON.stringify({ prop, other })); process.exit(1); }
const tag = `Smoke${Date.now()}`;
const person = { first_name: 'Test', last_name: tag, role: 'Accounting', email: 'fred@ayache.com', property_id: prop.id };
let rowId = 0;
try {
  // 1. add
  const r1 = await callFn({ action: 'add_jobber_contact', client_id: CLIENT_ROW, contact: person });
  check('add: ok, added', r1.ok === true && r1.jobber === 'added', JSON.stringify(r1));
  rowId = Number(r1.jobber_contact_row_id) || 0;
  const mine = (await nodes()).filter((n) => n.lastName === tag);
  check('Jobber holds the person once, on the property picked', mine.length === 1 && mine[0].listedOn === prop.source_id, JSON.stringify(mine.map((n) => n.listedOn)));
  check('role landed', mine[0]?.role === 'Accounting');
  check('not a billing contact; Jobber automatic messages all off',
    mine[0]?.isBillingContact === false && mine[0]?.receivesReminders === false && mine[0]?.receivesFollowUps === false &&
    mine[0]?.receivesQuoteFollowUps === false && mine[0]?.receivesInvoiceFollowUps === false && mine[0]?.canAccessClientHub === false,
    JSON.stringify(mine[0]));
  const [row] = await sql(`select email, jobber_role, property_gids, deleted_at from public.client_jobber_contacts where id = ${rowId}`);
  check('mirror row written with its property', row?.email === 'fred@ayache.com' && row?.deleted_at === null &&
    JSON.stringify(row?.property_gids ?? []).includes(prop.source_id), JSON.stringify(row));

  // 2. the same save again (a retry after a lost reply) adds nobody
  const r2 = await callFn({ action: 'add_jobber_contact', client_id: CLIENT_ROW, contact: person });
  check('retry: ok, already there, same row', r2.ok === true && r2.jobber === 'already_there' && Number(r2.jobber_contact_row_id) === rowId, JSON.stringify(r2));
  check('Jobber still holds the person once', (await nodes()).filter((n) => n.lastName === tag).length === 1);

  // 3. the page-open refresh keeps a property contact (before 2026-11-13 it read client.contacts only and would retire it)
  const rf = await callFn({ action: 'refresh', client_id: CLIENT_ROW });
  const [row3] = await sql(`select deleted_at from public.client_jobber_contacts where id = ${rowId}`);
  check('refresh: ok, complete, the property contact kept', rf.ok === true && rf.complete === true && row3?.deleted_at === null, JSON.stringify(rf).slice(0, 200));

  // 4. edit the property contact through edit_jobber_contact (before, it answered "gone"), and it stays on its property
  const e1 = await callFn({ action: 'edit_jobber_contact', jobber_contact_row_id: rowId, patch: { jobber_role: 'Owner' } });
  const after4 = (await nodes()).filter((n) => n.lastName === tag);
  check('edit: ok, role changed in Jobber, still on the property', e1.ok === true && after4[0]?.role === 'Owner' && after4[0]?.listedOn === prop.source_id, JSON.stringify(e1));

  // 5. another client's property is refused before Jobber is touched
  const r5 = await callFn({ action: 'add_jobber_contact', client_id: CLIENT_ROW, contact: { ...person, last_name: tag + 'X', property_id: other.id } });
  check('other client property refused on its field', r5.ok === false && r5.field === 'property_id', JSON.stringify(r5));
  check('nothing added for it', (await nodes()).filter((n) => n.lastName === tag + 'X').length === 0);

  // 6. a missing first name and a bad email are refused on their fields
  const r6 = await callFn({ action: 'add_jobber_contact', client_id: CLIENT_ROW, contact: { ...person, first_name: '' } });
  const r7 = await callFn({ action: 'add_jobber_contact', client_id: CLIENT_ROW, contact: { ...person, email: 'not-an-email' } });
  check('no first name refused', r6.ok === false && r6.field === 'first_name', JSON.stringify(r6));
  check('bad email refused', r7.ok === false && r7.field === 'email', JSON.stringify(r7));
} finally {
  await cleanup((n) => n.firstName === 'Test' && (n.lastName || '').startsWith(tag));
  const [gone] = await sql(`select deleted_at from public.client_jobber_contacts where id = ${rowId}`);
  check('mirror row retired', !rowId || gone?.deleted_at !== null);
}
console.log(failures ? `${failures} FAILED` : 'ALL PASS');
process.exit(failures ? 1 : 0);
