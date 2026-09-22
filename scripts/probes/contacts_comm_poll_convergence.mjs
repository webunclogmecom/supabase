// contacts_comm_poll_convergence.mjs - step 3 of the Contacts Role + Communication build.
//
// 🛑 THE CLAIM THIS EXISTS TO TURN INTO EVIDENCE:
//   "The */5 Jobber poll cannot clear person_role / person_role_other."
//
// The claim rests on PostgREST semantics: webhook-jobber's handleClient upserts
// public.client_contacts with a SIX-key payload
//   {client_id, property_id, contact_role, name, email, phone}
// via .upsert(row, {onConflict:'client_id,property_id,contact_role'}), and save-client-contact's
// {action:'refresh'} upserts public.client_jobber_contacts with a FOURTEEN-key payload. PostgREST
// emits ON CONFLICT DO UPDATE SET <payload keys only>, so a column absent from the payload is
// never in the SET list and survives.
//
// 🛑 READING THE SOURCE IS NOT EVIDENCE. Reading it tells you what we INTEND PostgREST to emit.
// This script sends the real payloads through the real transport and reads the result back, and
// then MUTATES each payload by adding person_role to it and requires the value to be LOST. A probe
// that only ever exercises the surviving case cannot tell a real guarantee from a coincidence.
//
// 🛑 EVERY SURVIVAL ASSERTION IS PAIRED WITH A CONTROL THAT THE WRITE ACTUALLY HAPPENED, because
// "person_role survived" is exactly what you also observe when nothing ran at all:
//   * client_contacts   -> updated_at must MOVE (set_updated_at fires NEW.updated_at = NOW()
//                          unconditionally on UPDATE, so a moved value proves the DO UPDATE branch
//                          executed on THIS row)
//   * client_jobber_contacts -> synced_at must MOVE (it is in the refresh payload)
//   * the end-to-end poll    -> raw.jobber_pull_clients.needs_populate must go TRUE -> FALSE
//                          (proves the handler was actually replayed)
//
//   node scripts/probes/contacts_comm_poll_convergence.mjs --mechanism   transport + mutation
//   node scripts/probes/contacts_comm_poll_convergence.mjs --poll        end-to-end through cron
//   node scripts/probes/contacts_comm_poll_convergence.mjs               both
//
// SAFETY. It touches ONLY client 381 (112-YA, the sanctioned test client) and only the two columns
// it owns. Every write is restored in a finally, and the restore is verified rather than assumed.
// It never emails anyone, never touches Jobber, and never writes another client.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const env = Object.fromEntries(
  readFileSync(join(ROOT, '.env'), 'utf8').split(/\r?\n/)
    .filter((l) => /^[A-Z_]+=/.test(l))
    .map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '').trim()])
);

const REF        = env.SUPABASE_PROJECT_ID;
const CLIENT_DB  = 381;
const CLIENT_GID = 'Z2lkOi8vSm9iYmVyL0NsaWVudC8xMDY1Njc0MDQ=';
const CONTACT_ID = 484;          // the client-record mirror row webhook-jobber synthesises
const SENTINEL   = 'owner';      // a legal person_role value; nothing else on 112-YA uses it

const args = new Set(process.argv.slice(2));
const RUN_MECH = args.has('--mechanism') || args.size === 0;
const RUN_POLL = args.has('--poll')      || args.size === 0;

const fails = [];
let ran = 0;
const check = (name, ok, detail) => {
  ran += 1;
  if (!ok) fails.push(`${name}: ${detail}`);
  console.log(`  ${ok ? 'ok  ' : 'FAIL'}  ${name}${ok ? '' : '  <- ' + detail}`);
};

// ---- transports --------------------------------------------------------------------------
const sql = async (q) => {
  const r = await fetch(`https://api.supabase.com/v1/projects/${REF}/database/query`, {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q }),
  });
  const j = await r.json();
  if (!Array.isArray(j)) throw new Error('DB query failed: ' + JSON.stringify(j).slice(0, 400));
  return j;
};

// the REAL transport the poll and the refresh use
const rest = async (path, { method = 'GET', body, prefer } = {}) => {
  const r = await fetch(`https://${REF}.supabase.co/rest/v1/${path}`, {
    method,
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: 'Bearer ' + env.SUPABASE_SERVICE_ROLE_KEY,
      'Content-Type': 'application/json',
      ...(prefer ? { Prefer: prefer } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const text = await r.text();
  if (!r.ok) throw new Error(`PostgREST ${r.status} on ${path}: ${text.slice(0, 300)}`);
  return text ? JSON.parse(text) : null;
};

const readContact = async () =>
  (await sql(`select to_jsonb(c) as j from public.client_contacts c where c.id = ${CONTACT_ID};`))[0].j;

const readJobberContact = async (id) =>
  (await sql(`select to_jsonb(c) as j from public.client_jobber_contacts c where c.id = ${id};`))[0].j;

const setRole = async (table, id, value) => {
  const v = value === null ? 'null' : `'${value}'`;
  await sql(`update public.${table} set person_role = ${v} where id = ${id} and client_id = ${CLIENT_DB};`);
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- the payloads, copied from the real writers ------------------------------------------
// webhook-jobber/index.ts handleClient, the six keys it sends. Kept in this shape ON PURPOSE:
// if somebody adds a key there, this probe should be updated in the same change and the
// mutation arm below says what that costs.
const pollPayload = (c) => ({
  client_id: c.client_id,
  property_id: null,
  contact_role: 'primary',
  name: c.name,
  email: c.email,
  phone: c.phone,
});

// save-client-contact/index.ts action:"refresh", the fourteen keys it sends.
const refreshPayload = (j) => ({
  client_id: j.client_id,
  jobber_contact_id: j.jobber_contact_id,
  first_name: j.first_name,
  last_name: j.last_name,
  name: j.name,
  jobber_role: j.jobber_role,
  title: j.title,
  is_billing_contact: j.is_billing_contact,
  email: j.email,
  phone: j.phone,
  property_gids: j.property_gids,
  deleted_at: null,
  synced_at: new Date().toISOString(),
  updated_at: new Date().toISOString(),
});

// ==========================================================================================
async function mechanism() {
  console.log('\n=== MECHANISM: the real PostgREST transport, then the same call mutated ===');

  const base = await readContact();
  if (base.client_id !== CLIENT_DB) throw new Error('refusing to touch a client other than 112-YA');
  const jbase0 = (await sql(
    `select to_jsonb(c) as j from public.client_jobber_contacts c
      where c.client_id = ${CLIENT_DB} and c.deleted_at is null order by c.id limit 1;`))[0]?.j;
  if (!jbase0) throw new Error('112-YA holds no live Jobber contact row to test against');

  try {
    // ---------------- client_contacts, the poll's shape ----------------
    await setRole('client_contacts', CONTACT_ID, SENTINEL);
    const before = await readContact();
    check('setup: person_role is set', before.person_role === SENTINEL, `got ${before.person_role}`);

    await sleep(1100);   // so a moved updated_at is unambiguous at second resolution
    await rest('client_contacts?on_conflict=client_id,property_id,contact_role', {
      method: 'POST', body: pollPayload(before),
      prefer: 'resolution=merge-duplicates,return=minimal',
    });
    const after = await readContact();

    // the control: the row really was rewritten by that upsert
    check('poll-shape upsert rewrote the row (control)',
      after.updated_at !== before.updated_at,
      `updated_at did not move (${before.updated_at}); the survival below would prove nothing`);
    check('poll-shape upsert left person_role intact',
      after.person_role === SENTINEL, `person_role became ${after.person_role}`);
    check('poll-shape upsert left name byte-identical',
      after.name === before.name, `name became ${after.name}`);

    // ---------------- the MUTATION: add the column to the payload ----------------
    await sleep(1100);
    await rest('client_contacts?on_conflict=client_id,property_id,contact_role', {
      method: 'POST', body: { ...pollPayload(before), person_role: null },
      prefer: 'resolution=merge-duplicates,return=minimal',
    });
    const mutated = await readContact();
    check('MUTATION: naming person_role in the payload DOES clear it',
      mutated.person_role === null,
      `person_role is still ${mutated.person_role} - the reader cannot see a loss, so every ` +
      'survival assertion above is vacuous');

    // ---------------- client_jobber_contacts, the refresh shape ----------------
    await setRole('client_jobber_contacts', jbase0.id, SENTINEL);
    const jbefore = await readJobberContact(jbase0.id);
    check('setup: jobber person_role is set', jbefore.person_role === SENTINEL, `got ${jbefore.person_role}`);

    await rest('client_jobber_contacts?on_conflict=jobber_contact_id', {
      method: 'POST', body: refreshPayload(jbefore),
      prefer: 'resolution=merge-duplicates,return=minimal',
    });
    const jafter = await readJobberContact(jbase0.id);
    check('refresh-shape upsert rewrote the row (control)',
      jafter.synced_at !== jbefore.synced_at,
      `synced_at did not move (${jbefore.synced_at})`);
    check('refresh-shape upsert left person_role intact',
      jafter.person_role === SENTINEL, `person_role became ${jafter.person_role}`);

    await rest('client_jobber_contacts?on_conflict=jobber_contact_id', {
      method: 'POST', body: { ...refreshPayload(jbefore), person_role: null },
      prefer: 'resolution=merge-duplicates,return=minimal',
    });
    const jmut = await readJobberContact(jbase0.id);
    check('MUTATION: same on the Jobber mirror table',
      jmut.person_role === null, `person_role is still ${jmut.person_role}`);
  } finally {
    await setRole('client_contacts', CONTACT_ID, null);
    await setRole('client_jobber_contacts', jbase0.id, null);
    const back  = await readContact();
    const jback = await readJobberContact(jbase0.id);
    check('RESTORED: client_contacts.person_role is null again', back.person_role === null, `got ${back.person_role}`);
    check('RESTORED: jobber person_role is null again', jback.person_role === null, `got ${jback.person_role}`);
    check('RESTORED: name/email/phone untouched',
      back.name === base.name && back.email === base.email && back.phone === base.phone,
      'the mirror row is not what it was before the probe');
  }
}

// ==========================================================================================
async function pollEndToEnd() {
  console.log('\n=== END TO END: the real */5 poll replays the client ===');

  const base = await readContact();
  try {
    await setRole('client_contacts', CONTACT_ID, SENTINEL);
    const before = await readContact();
    check('setup: person_role is set', before.person_role === SENTINEL, `got ${before.person_role}`);

    // arm the replay: flag the staged row so the poll re-POSTs this client's CLIENT_UPDATE
    await sql(`update raw.jobber_pull_clients
                  set needs_populate = true
                where data->>'id' = '${CLIENT_GID}';`);
    const armed = await sql(`select needs_populate from raw.jobber_pull_clients
                              where data->>'id' = '${CLIENT_GID}';`);
    check('setup: staged row armed', armed[0]?.needs_populate === true, JSON.stringify(armed));

    await sql(`select public.fn_request_jobber_sync('poll');`);

    // measured reaction is ~20s; poll to 90s so a slow run does not read as a pass
    let drained = false, after = before;
    for (let i = 0; i < 18 && !drained; i++) {
      await sleep(5000);
      const st = await sql(`select needs_populate from raw.jobber_pull_clients
                             where data->>'id' = '${CLIENT_GID}';`);
      drained = st[0]?.needs_populate === false;
      after = await readContact();
      process.stdout.write(`    t+${(i + 1) * 5}s needs_populate=${st[0]?.needs_populate} ` +
        `person_role=${after.person_role} updated_at_moved=${after.updated_at !== before.updated_at}\n`);
    }

    // 🛑 THE CONTROL. Without it, "person_role survived" only means the poll never ran.
    check('the poll actually replayed this client (control)', drained,
      'needs_populate never went back to false within 90s, so nothing was proven');
    check('the poll rewrote the mirror row (control)',
      after.updated_at !== before.updated_at,
      'updated_at did not move: the upsert did not reach this row, so survival proves nothing');
    check('person_role survived the poll', after.person_role === SENTINEL,
      `person_role became ${after.person_role}`);
    check('name survived the poll byte-identically', after.name === before.name,
      `name became ${after.name}`);
  } finally {
    await setRole('client_contacts', CONTACT_ID, null);
    const back = await readContact();
    check('RESTORED: person_role is null again', back.person_role === null, `got ${back.person_role}`);
    check('RESTORED: name/email/phone untouched',
      back.name === base.name && back.email === base.email && back.phone === base.phone,
      'the mirror row is not what it was before the probe');
  }
}

// ==========================================================================================
try {
  if (RUN_MECH) await mechanism();
  if (RUN_POLL) await pollEndToEnd();
} catch (e) {
  console.log('\nABORTED: ' + e.message);
  fails.push('aborted: ' + e.message);
}

console.log(`\n${ran} assertions, ${fails.length} failure(s)`);
if (fails.length) { fails.forEach((f) => console.log('  FAIL ' + f)); process.exit(1); }
console.log('PASS');
