#!/usr/bin/env node
/**
 * FULL-CRUD SMOKE TEST for properties.lock_box_key, driven through the paths the CLIENT APP
 * actually uses. Fred, 2026-09-02: "we need a smoke test from our app to make sure it works
 * correctly, and it needs the full crud, like removing it (leaving it blank), update
 * (editing it), creating it (putting something), reading it".
 *
 *   node scripts/probes/lock_box_crud_smoke.js                 # empty-baseline subject
 *   node scripts/probes/lock_box_crud_smoke.js --property=32   # a subject that already has one
 *
 * ============================================================================
 * ONE STATEMENT PER STEP, AND THAT IS THE WHOLE POINT
 * ============================================================================
 * 🛑 The first version of this file ran every step inside a single DO block that ended with
 * `RAISE EXCEPTION 'SMOKE PASSED'`. A RAISE ABORTS THE TRANSACTION, so every write it had just
 * asserted was rolled back. It passed loudly while proving nothing about persistence, and its
 * own header claimed the opposite. It was caught by a check that had nothing to do with the
 * assertions: `audit.logs` held ZERO rows for the subject after a run that made six writes,
 * against three rows from the UI writes minutes earlier. **A test that cannot leave a trace did
 * not do anything.**
 *
 * So each step is now its own HTTP call and therefore its own transaction, which is also what
 * the modal does: every Save is a separate round trip. The assertions live in JS, between the
 * statements, reading the state back rather than trusting the call that just returned.
 *
 * WRITE -> client.update_property_operational(property_id, patch). The modal sends ONE patch of
 *          changed keys; lock_box_key is just another key in it. There is no separate RPC.
 * READ  -> client.properties. The app does NOT read public.properties. Forgetting that view is
 *          what made the field render an empty box over a stored 5713 on the day it shipped, so
 *          a smoke test asserting only the base table would have passed while the app showed
 *          nothing. Every step asserts BOTH.
 *
 * The RPC gates on auth.uid() and a staff email domain, so each step sets request.jwt.claims the
 * way PostgREST would, in the same statement as the call (a transaction-local setting does not
 * survive to the next round trip).
 *
 * ============================================================================
 * THE CASE THAT MATTERS MOST IS "REMOVE"
 * ============================================================================
 * Clearing is the untested half of every field in this estate: every test that sets a real value
 * passes while the empty path silently writes '' or nothing at all. DELETE therefore asserts SQL
 * NULL and NOT the empty string, and a whitespace-only case follows it, because "   " is what an
 * operator actually leaves behind.
 *
 * IT COMMITS, and the subject is restored in a `finally` so a failed run cannot leave it dirty.
 * ⚠ public.properties is audited, so a run leaves a trail attributed to this probe. That trail is
 * the evidence the run happened, not noise: an empty one means the test did nothing.
 */
const fs = require('fs'), path = require('path');
const PROPERTY = Number(process.argv.find(a => /^--property=/.test(a))?.split('=')[1] || 2);
const CLAIMS = `{"sub":"00000000-0000-0000-0000-000000000009","email":"smoke@ayache.com"}`;

const repoRoot = path.resolve(__dirname, '..', '..');
const env = Object.fromEntries(
  fs.readFileSync(path.join(repoRoot, '.env'), 'utf8')
    .split(/\r?\n/).filter(l => l.includes('='))
    .map(l => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]));

async function sql(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_ID}/database/query`,
    { method: 'POST', headers: { Authorization: `Bearer ${env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ query: q }) });
  const t = await r.text(); let j; try { j = JSON.parse(t); } catch { throw new Error('non-JSON: ' + t.slice(0, 300)); }
  if (j && j.message) throw new Error(j.message);
  return j;
}
const lit = (v) => v === null ? 'null' : `'${String(v).replace(/'/g, "''")}'`;

// One patch through the RPC, in its own transaction. No RAISE on the happy path, so it COMMITS.
const save = (patchJson) => sql(
  `DO $s$ BEGIN
     PERFORM set_config('request.jwt.claims', '${CLAIMS}', true);
     PERFORM client.update_property_operational(${PROPERTY}, '${patchJson}'::jsonb);
   END $s$;`);

const readBoth = async () => (await sql(
  `select (select lock_box_key from public.properties where id=${PROPERTY}) as col,
          (select lock_box_key from client.properties  where id=${PROPERTY}) as vw,
          (select lock_box_key is null from public.properties where id=${PROPERTY}) as col_is_null`))[0];

// A save that MUST be refused. Returns the SQLSTATE so the caller can tell a refusal from a pass.
const saveExpectingRefusal = async (patchJson) => {
  try { await save(patchJson); return null; } catch (e) { return String(e.message); }
};

const fails = [];
const steps = [];
const check = (ok, msg) => { if (!ok) fails.push(msg); };

(async () => {
  const start = await readBoth();
  if (start.col === undefined) throw new Error(`property ${PROPERTY} not found`);
  const started = start.col;
  console.log(`subject ${PROPERTY}, starting value ${started === null ? 'NULL' : JSON.stringify(started)}`);

  const auditBefore = (await sql(
    `select count(*)::int as n from audit.logs where table_name='properties'
      and record_pk = '{"id":${PROPERTY}}'::jsonb`))[0].n;

  try {
    // ---- CREATE (on a populated subject this is an overwrite, which is the same write) ----
    await save('{"lock_box_key":"A-14"}');
    let s = await readBoth();
    check(s.col === 'A-14', `CREATE: base table holds ${JSON.stringify(s.col)}`);
    check(s.vw === 'A-14', `CREATE: client.properties holds ${JSON.stringify(s.vw)} (the app would render that)`);
    steps.push('CREATE');

    // ---- READ: a separate round trip, because the modal re-fetches rather than trusting ----
    s = await readBoth();
    check(s.vw === 'A-14', `READ: view disagrees on re-read (${JSON.stringify(s.vw)})`);
    steps.push('READ');

    // ---- UPDATE ----
    await save('{"lock_box_key":"C1709x"}');
    s = await readBoth();
    check(s.col === 'C1709x', `UPDATE: base table kept ${JSON.stringify(s.col)}`);
    check(s.vw === 'C1709x', `UPDATE: view kept ${JSON.stringify(s.vw)}`);
    steps.push('UPDATE');

    // ---- DELETE, the half that normally goes untested ----
    await save('{"lock_box_key":""}');
    s = await readBoth();
    check(s.col_is_null === true,
      `DELETE: expected SQL NULL, got ${JSON.stringify(s.col)} - an empty string is a second representation of "no lock box"`);
    check(s.vw === null, `DELETE: view still shows ${JSON.stringify(s.vw)}`);
    steps.push('DELETE');

    // ---- whitespace-only clears too ----
    await save('{"lock_box_key":"A-14"}');
    await save('{"lock_box_key":"   "}');
    s = await readBoth();
    check(s.col_is_null === true, `WHITESPACE: stored ${JSON.stringify(s.col)} instead of NULL`);
    steps.push('WHITESPACE');

    // ---- the guards must refuse, and refusal must be visible ----
    const tooLong = await saveExpectingRefusal(`{"lock_box_key":"${'x'.repeat(101)}"}`);
    check(tooLong !== null, 'GUARD: a 101-character value was accepted');
    const ctrl = await saveExpectingRefusal('{"lock_box_key":"A\\nB"}');
    check(ctrl !== null, 'GUARD: a control character was accepted');
    steps.push('GUARDS');
  } finally {
    // Restore whatever the subject started with, pass or fail. Direct write: this is bookkeeping,
    // not a step under test, and it must run even when the RPC is the thing that is broken.
    await sql(`update public.properties set lock_box_key = ${lit(started)} where id = ${PROPERTY}`);
    const back = await readBoth();
    check(back.col === started, `RESTORE: left at ${JSON.stringify(back.col)}, started at ${JSON.stringify(started)}`);
  }

  // ---- the run must have left a trace. An audited table plus zero new rows means the writes
  //      were rolled back, which is exactly how the first version of this file passed while
  //      doing nothing at all.
  const auditAfter = (await sql(
    `select count(*)::int as n from audit.logs where table_name='properties'
      and record_pk = '{"id":${PROPERTY}}'::jsonb`))[0].n;
  const wrote = auditAfter - auditBefore;
  check(wrote > 0, `PERSISTENCE: ${wrote} new audit rows - the writes did not commit`);

  if (fails.length) {
    console.error('FAIL  ' + fails.join(' | ') + `   [ran: ${steps.join(', ')}]`);
    process.exit(1);
  }
  console.log(`PASS  ${steps.join(', ')}; committed (${wrote} audit rows); subject restored to ${started === null ? 'NULL' : JSON.stringify(started)}`);
})().catch(e => { console.error('ERROR ' + e.message); process.exit(2); });
