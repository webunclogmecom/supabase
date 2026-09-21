// SMOKE: save-client-contact action:'promote' - making a person's details the client's own.
//
// Jobber has NO primary-contact flag (751-type sweep, positive control returned Email.primary and
// ClientPhoneNumber.primary and nothing else), so promote is defined as Fred decided: COPY that
// person's email and phone onto the Jobber CLIENT's own primary Email and ClientPhoneNumber.
//
// WHAT IT PROVES
//   1. Preview states the truth, including whether the DERM manifest recipient moves, computed by
//      client.fn_derm_recipient - the same function send-derm-email uses.
//   2. The comma refusal fires IN THE EDGE FUNCTION, not just the UI. 20 of 22 city rows hold
//      several addresses in one string; Jobber would store it and the verify would PASS.
//   3. A real promote lands in Jobber, the promoted person KEEPS their own address (it is a copy,
//      not a move), and the DERM recipient follows. Then it is put back.
//
// Run: cd Slack && JT=$(./jobber-token.sh) && cd ../Supabase && JT=$JT node scripts/probes/promote_contact_smoke.mjs
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
  method: 'POST', headers: { Authorization: `Bearer ${JT}`, 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16', 'Content-Type': 'application/json' },
  body: JSON.stringify({ query, variables }) })).json();

const Q = `query($id: EncodedId!) { client(id: $id) {
  emails { id address primary } phones { id number primary }
  contacts(first:5){ nodes { id emails(first:3){nodes{address primary}} } } } }`;
const readJ = async () => (await jobber(Q, { id: CLIENT_GID }))?.data?.client;
const clientEmail = c => (c?.emails || []).find(e => e.primary)?.address ?? null;
const clientPhone = c => (c?.phones || []).find(p => p.primary)?.number ?? null;
const personEmail = c => ((c?.contacts?.nodes || []).find(n => n.id === CONTACT_GID)?.emails?.nodes || []).find(e => e.primary)?.address ?? null;

const g = await (await fetch(`${U}/auth/v1/admin/generate_link`, { method: 'POST',
  headers: { apikey: SR, Authorization: `Bearer ${SR}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ type: 'magiclink', email: 'fred@ayache.com' }) })).json();
const v = await (await fetch(`${U}/auth/v1/verify`, { method: 'POST', headers: { apikey: SR, 'Content-Type': 'application/json' },
  body: JSON.stringify({ type: 'magiclink', token_hash: g.hashed_token }) })).json();
if (!v?.access_token) { console.log('FATAL: no staff session'); process.exit(1); }
const callFn = async (b) => await (await fetch(`${U}/functions/v1/save-client-contact`, {
  method: 'POST', headers: { Authorization: `Bearer ${v.access_token}`, 'Content-Type': 'application/json', apikey: SR },
  body: JSON.stringify(b) })).json();

await callFn({ action: 'refresh', client_id: CLIENT_ROW });
const [jrow] = await sql(`select id, email, phone from public.client_jobber_contacts
  where client_id=${CLIENT_ROW} and jobber_contact_id='${CONTACT_GID}' and deleted_at is null;`);
if (!jrow) { console.log('FATAL: Jobber contact not mirrored'); process.exit(1); }

const base = await readJ();
console.log('BASELINE');
console.log(`  client email/phone : ${clientEmail(base)} / ${clientPhone(base)}`);
console.log(`  the person's own   : ${personEmail(base)} / ${jrow.phone}`);

// ---- 1. preview ------------------------------------------------------------------------------
console.log('\n1. preview promoting the Jobber person');
const pv = await callFn({ action: 'promote', client_id: CLIENT_ROW, jobber_contact_row_id: jrow.id, preview: true });
console.log('   ', JSON.stringify(pv).slice(0, 400));
check('preview ok and no refusal', pv?.ok === true && pv?.refusal === null, JSON.stringify(pv?.refusal ?? ''));
check('states the client email that would change', pv?.client_record?.email === clientEmail(base));
check('states what it becomes', pv?.after?.email === jrow.email);
check('says the DERM recipient MOVES', pv?.derm?.moves === true, JSON.stringify(pv?.derm));
check('and names both DERM addresses', pv?.derm?.now === clientEmail(base) && pv?.derm?.after === jrow.email, JSON.stringify(pv?.derm));

// ---- 2. the comma refusal, on a real multi-address row ---------------------------------------
console.log('\n2. comma refusal, on a real city row that holds several addresses');
const [bag] = await sql(`select id, client_id, email from public.client_contacts
  where contact_role='city' and email like '%,%' order by id limit 1;`);
if (bag) {
  const r = await callFn({ action: 'promote', client_id: bag.client_id, contact_id: bag.id, preview: true });
  console.log(`   row ${bag.id}: ${String(bag.email).slice(0, 70)}...`);
  check('preview reports the refusal', r?.refusal?.code === 'multi_address', JSON.stringify(r?.refusal ?? r).slice(0, 160));
  const hard = await callFn({ action: 'promote', client_id: bag.client_id, contact_id: bag.id });
  check('and the REAL call is refused BY THE FUNCTION, not just hidden in the UI',
    hard?.ok === false && hard?.code === 'multi_address', `code=${hard?.code}`);
} else { console.log('   SKIPPED - no comma-bearing city row found'); }

// ---- 2b. Jobber validates the phone it is given -----------------------------------------------
// 112-YA's contact carries 555-555-5555, which Jobber REFUSES as a client phone because it cannot
// receive texts. That refusal is correct and is left in place as its own check; then the phone is
// temporarily made valid so the rest of the promote path is actually exercised rather than blocked.
console.log('\n2b. Jobber refuses a non-textable number, and we say so in plain words');
const bad = await callFn({ action: 'promote', client_id: CLIENT_ROW, jobber_contact_row_id: jrow.id });
check('refused', bad?.ok === false && bad?.code === 'jobber_rejected', `code=${bad?.code}`);
check('and the message is ours, not Jobber jargon',
  /will not accept a number that cannot receive texts/.test(String(bad?.message)), String(bad?.message).slice(0, 170));
const midJ = await readJ();
check('nothing moved on the refusal', clientEmail(midJ) === clientEmail(base), String(clientEmail(midJ)));

const VALID_PHONE = '7863255599';
await callFn({ action: 'edit_jobber_contact', jobber_contact_row_id: jrow.id, patch: { phone: VALID_PHONE } });
const [jrow2] = await sql(`select id, email, phone from public.client_jobber_contacts where id=${jrow.id};`);
console.log(`   person's phone temporarily set to ${jrow2?.phone} so the promote can run`);

// ---- 3. the real promote, then back ----------------------------------------------------------
console.log('\n3. promote for real');
const go = await callFn({ action: 'promote', client_id: CLIENT_ROW, jobber_contact_row_id: jrow.id });
console.log('   ', JSON.stringify(go).slice(0, 220));
check('promote reported ok', go?.ok === true, go?.message ? String(go.message).slice(0, 140) : '');
check('and recorded how it happened', String(go?.via ?? '').startsWith('promote:'), String(go?.via));

const afterJ = await readJ();
check("the CLIENT's primary email is now the person's", clientEmail(afterJ) === jrow.email, String(clientEmail(afterJ)));
check('the person KEPT their own email (copy, not move)', personEmail(afterJ) === personEmail(base), String(personEmail(afterJ)));
const [dermAfter] = await sql(`select client.fn_derm_recipient(${CLIENT_ROW}) ->> 'email' as e;`);
check('the DERM recipient followed', dermAfter?.e === jrow.email, String(dermAfter?.e));

console.log('\n   putting it back');
const back = await callFn({ contact_id: pv.client_record.contact_id, patch: { email: clientEmail(base), phone: clientPhone(base) } });
check('restore accepted', back?.ok === true, back?.message ? String(back.message).slice(0, 140) : '');
const finalJ = await readJ();
check('client email/phone back to baseline',
  clientEmail(finalJ) === clientEmail(base) && clientPhone(finalJ)?.replace(/\D/g, '') === clientPhone(base)?.replace(/\D/g, ''),
  `${clientEmail(finalJ)} / ${clientPhone(finalJ)}`);
const [dermFinal] = await sql(`select client.fn_derm_recipient(${CLIENT_ROW}) ->> 'email' as e;`);
check('DERM recipient back to baseline', dermFinal?.e === clientEmail(base), String(dermFinal?.e));

// restore the person's own phone too, so the client is left exactly as found
await callFn({ action: 'edit_jobber_contact', jobber_contact_row_id: jrow.id, patch: { phone: jrow.phone } });
const endJ = await readJ();
const [jrow3] = await sql(`select phone from public.client_jobber_contacts where id=${jrow.id};`);
check("the person's own phone restored", String(jrow3?.phone).replace(/\D/g, '') === String(jrow.phone).replace(/\D/g, ''),
  `${jrow.phone} -> ${jrow3?.phone}`);
check("the person's own email never moved throughout", personEmail(endJ) === personEmail(base), String(personEmail(endJ)));

console.log(`\n${failures === 0 ? 'ALL CHECKS PASSED' : failures + ' CHECK(S) FAILED'}`);
process.exit(failures === 0 ? 0 : 1);
