// SMOKE: save-client-contact's verify + rollback, after the 2026-09-21 four-defect fix.
//
// WHAT IT PROVES, and why each step has to be a real write:
//   1. CLEARING the primary email on a client that has a SECOND email now verifies as a
//      SUCCESS. Before the fix, pickPrimary's `?? a[0]` returned the survivor, `!gotEmail`
//      was false, and a clear that actually worked was rolled back and reported
//      verify_failed. 112-YA holds two emails, so it is exactly that shape.
//   2. The DELETE is undone by RE-ADDING (the old code emitted emailsToEdit on the id
//      Jobber had just destroyed, a guaranteed no-op that still reported success).
//   3. The drift guard refuses when our stored value is empty and Jobber holds one.
//
// SUBJECT: 112-YA only (client 381, contact 484), the sanctioned test client.
// It RESTORES the exact baseline addresses, descriptions and primary flags at the end and
// asserts the restore. The re-added Email object carries a NEW Jobber id; nothing here
// stores Email ids, so that is harmless and is reported rather than hidden.
//
// Run: cd Supabase && node scripts/probes/save_client_contact_rollback_smoke.mjs
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execSync } from 'node:child_process';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const env = Object.fromEntries(readFileSync(join(ROOT, '.env'), 'utf8').split(/\r?\n/)
  .filter(l => /^[A-Z_]+=/.test(l))
  .map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '').trim()]));
const U = `https://${env.SUPABASE_PROJECT_ID}.supabase.co`;
const SR = env.SUPABASE_SERVICE_ROLE_KEY;

const CLIENT_ROW = 381, CONTACT_ROW = 484;
const CLIENT_GID = 'Z2lkOi8vSm9iYmVyL0NsaWVudC8xMDY1Njc0MDQ=';
const say = (...a) => console.log(...a);
let failures = 0;
const check = (label, ok, detail = '') => {
  if (!ok) failures++;
  say(`  ${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? '  -- ' + detail : ''}`);
};

// ---- Jobber ------------------------------------------------------------------------------
// ⚠ execSync on Windows runs cmd.exe, which cannot run ./jobber-token.sh. Pass the token in:
//   cd Slack && JT=$(./jobber-token.sh) && cd ../Supabase && JT=$JT node scripts/probes/...
const JT = (process.env.JT || '').trim()
  || execSync('bash -lc "cd \'' + join(ROOT, '..', 'Slack') + '\' && ./jobber-token.sh"', { encoding: 'utf8' }).trim();
if (!JT) { console.log('FATAL: no Jobber token. Set JT=$(./jobber-token.sh).'); process.exit(1); }
const jobber = async (query, variables) => {
  const r = await fetch('https://api.getjobber.com/api/graphql', {
    method: 'POST',
    headers: { Authorization: `Bearer ${JT}`, 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16', 'Content-Type': 'application/json' },
    body: JSON.stringify({ query, variables }),
  });
  return await r.json();
};
const Q = 'query($id: EncodedId!) { client(id: $id) { emails { id address description primary } phones { id number description primary } } }';
const M = 'mutation($id: EncodedId!, $input: ClientEditInput!) { clientEdit(clientId: $id, input: $input) { userErrors { message path } } }';
const readJobber = async () => (await jobber(Q, { id: CLIENT_GID }))?.data?.client;
const shape = c => (c?.emails ?? []).map(e => `${e.address}/${e.description}/${e.primary}`).sort().join(' + ');

// ---- staff session, memory only ------------------------------------------------------------
const g = await (await fetch(`${U}/auth/v1/admin/generate_link`, { method: 'POST',
  headers: { apikey: SR, Authorization: `Bearer ${SR}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ type: 'magiclink', email: 'fred@ayache.com' }) })).json();
const v = await (await fetch(`${U}/auth/v1/verify`, { method: 'POST',
  headers: { apikey: SR, 'Content-Type': 'application/json' },
  body: JSON.stringify({ type: 'magiclink', token_hash: g.hashed_token }) })).json();
if (!v?.access_token) { say('FATAL: could not mint a staff session'); process.exit(1); }

const callFn = async (body) => {
  const r = await fetch(`${U}/functions/v1/save-client-contact`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${v.access_token}`, 'Content-Type': 'application/json', apikey: SR },
    body: JSON.stringify(body),
  });
  return { http: r.status, body: await r.json() };
};

// ---- BASELINE --------------------------------------------------------------------------------
const base = await readJobber();
const baseShape = shape(base);
say('BASELINE (live Jobber)');
for (const e of base.emails) say(`  EMAIL ${e.address} | ${e.description} | primary=${e.primary}`);
for (const p of base.phones) say(`  PHONE ${p.number} | ${p.description} | primary=${p.primary}`);
const basePrimary = base.emails.find(e => e.primary) ?? base.emails[0];
if (base.emails.length < 2) { say('\nFATAL: this smoke needs a client with TWO emails; 112-YA no longer has them.'); process.exit(1); }

// ---- 1. CLEAR the primary email, with a second email present ---------------------------------
say('\n1. CLEAR the primary email (the case that used to report a FALSE verify_failed)');
const cleared = await callFn({ contact_id: CONTACT_ROW, patch: { email: '' } });
say(`   http ${cleared.http}  code=${cleared.body?.code ?? '(none)'}  ok=${cleared.body?.ok}`);
if (cleared.body?.message) say(`   message: ${String(cleared.body.message).slice(0, 160)}`);
check('the clear is reported as a SUCCESS, not verify_failed',
  cleared.body?.ok === true && cleared.body?.code !== 'verify_failed',
  `code=${cleared.body?.code}`);

const afterClear = await readJobber();
check('the cleared Email object is GONE from Jobber',
  !(afterClear.emails ?? []).some(e => e.id === basePrimary.id));
check('the OTHER email survived (nothing collateral was destroyed)',
  (afterClear.emails ?? []).length === base.emails.length - 1,
  `${(afterClear.emails ?? []).length} left, expected ${base.emails.length - 1}`);
say(`   jobber now: ${shape(afterClear) || '(no emails)'}`);

// ---- 2. RESTORE the baseline, outside the function --------------------------------------------
say('\n2. RESTORE the baseline');
const restore = await jobber(M, { id: CLIENT_GID, input: { emailsToAdd: [{
  address: basePrimary.address,
  description: String(basePrimary.description ?? 'MAIN').toUpperCase(),
  primary: basePrimary.primary === true,
}] } });
check('restore accepted by Jobber', Array.isArray(restore?.data?.clientEdit?.userErrors) && restore.data.clientEdit.userErrors.length === 0,
  JSON.stringify(restore?.data?.clientEdit?.userErrors ?? restore?.errors ?? '').slice(0, 160));

// the re-added object also has to carry back the OTHER email's primary flag if Jobber moved it
const mid = await readJobber();
const other = (mid.emails ?? []).find(e => e.address !== basePrimary.address);
const baseOther = base.emails.find(e => e.address !== basePrimary.address);
if (other && baseOther && other.primary !== baseOther.primary) {
  await jobber(M, { id: CLIENT_GID, input: { emailsToEdit: [{ id: other.id, primary: baseOther.primary === true }] } });
  say(`   (also restored ${other.address} primary=${baseOther.primary})`);
}

const final = await readJobber();
say('FINAL (live Jobber)');
for (const e of final.emails) say(`  EMAIL ${e.address} | ${e.description} | primary=${e.primary}`);
check('final state is byte-identical to the baseline (address/description/primary)',
  shape(final) === baseShape, `\n      baseline: ${baseShape}\n      final   : ${shape(final)}`);
const newId = (final.emails ?? []).find(e => e.address === basePrimary.address)?.id;
say(`   note: the restored Email has a NEW Jobber id (${basePrimary.id.slice(-10)} -> ${String(newId).slice(-10)}). Nothing here stores Email ids.`);

say(`\n${failures === 0 ? 'ALL CHECKS PASSED' : failures + ' CHECK(S) FAILED'}`);
process.exit(failures === 0 ? 0 : 1);
