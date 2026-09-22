// contacts_112ya_baseline.mjs — step 0 of the Contacts Role + Communication build.
//
// Captures, verifies and restores the full contacts state of 112-YA across BOTH systems in one
// run, so every later step can prove it left the test client exactly as it found it.
//
//   node scripts/probes/contacts_112ya_baseline.mjs --capture           write the baseline
//   node scripts/probes/contacts_112ya_baseline.mjs --verify            live vs baseline, diff
//   node scripts/probes/contacts_112ya_baseline.mjs --verify --mutate   MUTATION TEST: must FAIL
//   node scripts/probes/contacts_112ya_baseline.mjs --restore           put Jobber back, then verify
//
// 🛑 WHY --mutate EXISTS. A verifier that always passes is not a verifier. --mutate corrupts one
// captured value in memory and re-runs the comparison; it MUST report a difference. If it passes,
// the comparison is blind and every "restored cleanly" claim built on it is worthless.
//
// 🛑 WHY VERIFY WAITS. The client-level mirror row is re-upserted from Jobber by the */5 poll,
// which was measured reacting in ~20 SECONDS. A restore verified at t+5s can be undone at t+20s.
// --restore therefore settles, re-reads, and reports the convergence rather than asserting once.
//
// Writes scripts/probes/_112ya_baseline.json, which is gitignored by the **/_*.json rule — it
// holds real client email addresses and both repos are PUBLIC.
//
// READS AND RESTORES. It never sends an email, never creates a quote or an invoice, and never
// touches a client other than 112-YA.
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execSync } from 'node:child_process';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const OUT = join(dirname(fileURLToPath(import.meta.url)), '_112ya_baseline.json');

const CLIENT_DB = 381;
const CLIENT_GID = 'Z2lkOi8vSm9iYmVyL0NsaWVudC8xMDY1Njc0MDQ=';

const env = Object.fromEntries(readFileSync(join(ROOT, '.env'), 'utf8').split(/\r?\n/)
  .filter((l) => /^[A-Z_]+=/.test(l))
  .map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '').trim()]));

const args = new Set(process.argv.slice(2));
const MODE = args.has('--capture') ? 'capture' : args.has('--restore') ? 'restore'
  : args.has('--verify') ? 'verify' : null;
const MUTATE = args.has('--mutate');
if (!MODE) { console.log('one of --capture | --verify | --restore is required'); process.exit(2); }

// ---- transports -------------------------------------------------------------------------------
const sql = async (q) => {
  const r = await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_ID}/database/query`, {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q }),
  });
  const j = await r.json();
  if (!Array.isArray(j)) throw new Error('DB query failed: ' + JSON.stringify(j).slice(0, 300));
  return j;
};

const JT = (process.env.JT || '').trim()
  || execSync(`bash -lc "cd '${join(ROOT, '..', 'Slack')}' && ./jobber-token.sh"`, { encoding: 'utf8' }).trim();
if (!JT) { console.log('FATAL: no Jobber token. Set JT=$(./jobber-token.sh).'); process.exit(1); }

const jobber = async (query, variables) => {
  const r = await fetch('https://api.getjobber.com/api/graphql', {
    method: 'POST',
    headers: { Authorization: `Bearer ${JT}`, 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16', 'Content-Type': 'application/json' },
    body: JSON.stringify({ query, variables }),
  });
  const j = await r.json();
  if (j.errors) throw new Error('Jobber: ' + JSON.stringify(j.errors).slice(0, 300));
  return j.data;
};

// ---- the shape we consider "the state" ---------------------------------------------------------
const Q_JOBBER = `query($id: EncodedId!) {
  client(id: $id) {
    id name firstName lastName companyName isCompany
    receivesReminders receivesFollowUps receivesQuoteFollowUps receivesInvoiceFollowUps receivesReviewRequests
    emails { id address description primary }
    phones { id number description primary smsAllowed }
    defaultEmails
    contacts(first: 25) { totalCount nodes {
      id firstName lastName name role title isBillingContact
      emails(first: 3) { nodes { id address description primary } }
      phones(first: 3) { nodes { id number description primary } }
      properties(first: 5) { nodes { id } } } }
  }
}`;

async function readLive() {
  const [contacts, client, jobberContacts, props] = await Promise.all([
    sql(`select id, client_id, property_id, contact_role, name, first_name, last_name, email, phone
           from public.client_contacts where client_id = ${CLIENT_DB} order by id;`),
    sql(`select id, client_code, name, primary_contact_ref from public.clients where id = ${CLIENT_DB};`),
    sql(`select id, jobber_contact_id, first_name, last_name, name, jobber_role, title,
                is_billing_contact, email, phone, property_gids, deleted_at
           from public.client_jobber_contacts where client_id = ${CLIENT_DB} order by id;`),
    sql(`select id, address, city_emails, is_billing, deleted_at
           from public.properties where client_id = ${CLIENT_DB} order by id;`),
  ]);
  const j = await jobber(Q_JOBBER, { id: CLIENT_GID });
  return { captured_at: new Date().toISOString(), db: { contacts, client, jobberContacts, props }, jobber: j.client };
}

// ---- comparison ---------------------------------------------------------------------------------
// Compares everything except the fields that legitimately move on their own.
const VOLATILE = new Set(['captured_at', 'synced_at', 'updated_at', 'created_at']);
function diff(a, b, path = '', out = []) {
  if (a === b) return out;
  const ka = a && typeof a === 'object', kb = b && typeof b === 'object';
  if (!ka || !kb) { out.push(`${path || '(root)'}: baseline ${JSON.stringify(a)} -> live ${JSON.stringify(b)}`); return out; }
  if (Array.isArray(a) !== Array.isArray(b)) { out.push(`${path}: shape changed`); return out; }
  const keys = [...new Set([...Object.keys(a), ...Object.keys(b)])];
  for (const k of keys) {
    if (VOLATILE.has(k)) continue;
    diff(a[k], b[k], path ? `${path}.${k}` : k, out);
  }
  return out;
}

// ---- modes ---------------------------------------------------------------------------------------
if (MODE === 'capture') {
  const state = await readLive();
  writeFileSync(OUT, JSON.stringify(state, null, 2), 'utf8');
  const c = state.jobber;
  console.log('CAPTURED ->', OUT);
  console.log(`  db contacts        : ${state.db.contacts.length} (${state.db.contacts.map((x) => x.id).join(', ')})`);
  console.log(`  primary_contact_ref: ${JSON.stringify(state.db.client[0]?.primary_contact_ref)}`);
  console.log(`  jobber mirror rows : ${state.db.jobberContacts.length}`);
  console.log(`  properties         : ${state.db.props.length}`);
  console.log(`  jobber emails      : ${c.emails.map((e) => `${e.address}${e.primary ? ' *' : ''}`).join(', ')}`);
  console.log(`  jobber phones      : ${c.phones.map((p) => `${p.number}${p.primary ? ' *' : ''}`).join(', ')}`);
  console.log(`  defaultEmails      : ${JSON.stringify(c.defaultEmails)}`);
  console.log(`  ContactModels      : ${c.contacts.totalCount} (${c.contacts.nodes.map((n) => `${n.name} billing=${n.isBillingContact}`).join('; ')})`);
  process.exit(0);
}

if (!existsSync(OUT)) { console.log(`FATAL: no baseline at ${OUT}. Run --capture first.`); process.exit(1); }
const base = JSON.parse(readFileSync(OUT, 'utf8'));

if (MODE === 'restore') {
  const live = await readLive();
  const b = base.jobber, l = live.jobber;
  const actions = [];

  // the star, on both channels
  const bStarEmail = b.emails.find((e) => e.primary), lStarEmail = l.emails.find((e) => e.primary);
  if (bStarEmail && lStarEmail && bStarEmail.id !== lStarEmail.id) {
    await jobber(`mutation($id: EncodedId!, $in: ClientEditInput!) { clientEdit(clientId:$id, input:$in){ userErrors{message} } }`,
      { id: CLIENT_GID, in: { emailsToEdit: [{ id: bStarEmail.id, primary: true }] } });
    actions.push(`starred email restored to ${bStarEmail.address}`);
  }
  const bStarPhone = b.phones.find((p) => p.primary), lStarPhone = l.phones.find((p) => p.primary);
  if (bStarPhone && lStarPhone && bStarPhone.id !== lStarPhone.id) {
    await jobber(`mutation($id: EncodedId!, $in: ClientEditInput!) { clientEdit(clientId:$id, input:$in){ userErrors{message} } }`,
      { id: CLIENT_GID, in: { phonesToEdit: [{ id: bStarPhone.id, primary: true }] } });
    actions.push(`starred phone restored to ${bStarPhone.number}`);
  }
  // billing flags on contacts we still recognise
  for (const bc of b.contacts.nodes) {
    const lc = l.contacts.nodes.find((n) => n.id === bc.id);
    if (lc && lc.isBillingContact !== bc.isBillingContact) {
      await jobber(`mutation($id: EncodedId!, $in: ClientEditInput!) { clientEdit(clientId:$id, input:$in){ userErrors{message} } }`,
        { id: CLIENT_GID, in: { contactsToEdit: [{ id: bc.id, isBillingContact: bc.isBillingContact }] } });
      actions.push(`isBillingContact on ${bc.name} restored to ${bc.isBillingContact}`);
    }
  }
  // contacts that exist now and did not at capture: report, never delete blind
  const extra = l.contacts.nodes.filter((n) => !b.contacts.nodes.some((x) => x.id === n.id));
  for (const e of extra) actions.push(`LEFT IN PLACE (delete by hand if it is yours): ContactModel ${e.name}`);

  console.log(actions.length ? 'RESTORE ACTIONS:' : 'RESTORE: nothing to do in Jobber.');
  actions.forEach((a) => console.log('  ' + a));

  // 🛑 settle before verifying: the poll re-upserts the mirror row in ~20s
  console.log('\nwaiting 45s for the poll to settle before verifying...');
  await new Promise((r) => setTimeout(r, 45000));
}

// ---- verify (also runs at the end of --restore) ---------------------------------------------------
const live = await readLive();
let baseline = base;
if (MUTATE) {
  // 🛑 THE MUTATION TEST. Corrupt one captured value; the diff MUST see it.
  baseline = JSON.parse(JSON.stringify(base));
  const star = baseline.jobber.emails.find((e) => e.primary) || baseline.jobber.emails[0];
  star.address = 'mutated@example.invalid';
  if (baseline.db.contacts[0]) baseline.db.contacts[0].email = 'mutated@example.invalid';
  console.log('MUTATION TEST: two captured values corrupted in memory. The diff MUST report them.\n');
}

const diffs = diff(baseline, live);
if (diffs.length === 0) {
  console.log('VERIFY: live state matches the baseline exactly.');
  console.log(`  defaultEmails: ${JSON.stringify(live.jobber.defaultEmails)}  (Jobber's memory; changed only by a real send)`);
  if (MUTATE) { console.log('\n🛑 MUTATION TEST FAILED: the comparison is BLIND. Do not trust any restore it approves.'); process.exit(1); }
  process.exit(0);
}
console.log(`VERIFY: ${diffs.length} difference(s) from the baseline:`);
diffs.forEach((d) => console.log('  ' + d));
if (MUTATE) { console.log('\nMUTATION TEST PASSED: the comparison sees a corrupted baseline.'); process.exit(0); }
process.exit(1);
