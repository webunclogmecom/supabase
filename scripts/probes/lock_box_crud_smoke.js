#!/usr/bin/env node
/**
 * FULL-CRUD SMOKE TEST for properties.lock_box_key, driven through the paths the CLIENT APP
 * actually uses. Fred, 2026-09-02: "we need a smoke test from our app to make sure it works
 * correctly, and it needs the full crud, like removing it (leaving it blank), update
 * (editing it), creating it (putting something), reading it".
 *
 *   node scripts/probes/lock_box_crud_smoke.js                  # default subject
 *   node scripts/probes/lock_box_crud_smoke.js --property=2
 *
 * ============================================================================
 * WHAT IT EXERCISES, AND WHY IT IS THESE TWO OBJECTS
 * ============================================================================
 * WRITE -> client.update_property_operational(property_id, patch). The modal sends ONE patch
 *          of changed keys; lock_box_key is just another key in it. There is no separate RPC.
 * READ  -> client.properties. The app does NOT read public.properties. Forgetting that view
 *          is what made the field render as an empty box over a stored 5713 on the day it
 *          shipped, so a smoke test that asserted only the base table would have passed while
 *          the app showed nothing. Every step below therefore asserts BOTH.
 *
 * The RPC gates on auth.uid() and a staff email domain, so the probe sets request.jwt.claims
 * the same way PostgREST would. That is deliberate: it exercises the statement the app emits
 * rather than a hand-rolled UPDATE that would prove nothing about the RPC's allow-list.
 *
 * ============================================================================
 * THE CASE THAT MATTERS MOST IS "REMOVE"
 * ============================================================================
 * Clearing is the untested half of every field in this estate: every test that sets a real
 * value passes while the empty path is the one that silently writes '' or nothing at all.
 * So the DELETE step asserts the column is SQL NULL and NOT the empty string, and there is a
 * whitespace-only case besides, because "   " is what a real operator leaves behind.
 *
 * IT COMMITS, ON PURPOSE. A rolled-back probe cannot prove the app path persists. The subject
 * is restored to the value it started with, and the run fails loudly if it is not - including
 * when an assertion throws, which is what the EXCEPTION block is for.
 * ⚠ public.properties is audited, so a run leaves audit rows attributed to this probe. That is
 * the intended trail, not noise.
 */
const fs = require('fs'), path = require('path');
const PROPERTY = Number(process.argv.find(a => /^--property=/.test(a))?.split('=')[1] || 2);

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

const BODY = `
DO $smoke$
DECLARE
  p_id     bigint := ${PROPERTY};
  started  text;
  fails    text := '';
  steps    text := '';
  col      text;
  vw       text;
  ret      jsonb;
  n        integer;
BEGIN
  SELECT lock_box_key INTO started FROM public.properties WHERE id = p_id;

  -- the app's identity. Without this the RPC raises 28000 and nothing below runs.
  PERFORM set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000009","email":"smoke@ayache.com"}', true);

  BEGIN
    ----------------------------------------------------------------- CREATE
    ret := client.update_property_operational(p_id, '{"lock_box_key":"A-14"}'::jsonb);
    SELECT lock_box_key INTO col FROM public.properties WHERE id = p_id;
    SELECT lock_box_key INTO vw  FROM client.properties  WHERE id = p_id;
    IF col IS DISTINCT FROM 'A-14' THEN fails := fails || 'CREATE: base table did not take the value; '; END IF;
    IF vw  IS DISTINCT FROM 'A-14' THEN fails := fails || 'CREATE: client.properties does not show it (the app would render an empty box); '; END IF;
    IF ret->>'lock_box_key' IS DISTINCT FROM 'A-14' THEN fails := fails || 'CREATE: the RPC return row omits it; '; END IF;
    steps := steps || 'CREATE ok; ';

    ----------------------------------------------------------------- READ
    -- Re-read on its own, because the app re-fetches after saving rather than trusting
    -- what it sent. If the view lagged, the modal would show a stale value.
    SELECT lock_box_key INTO vw FROM client.properties WHERE id = p_id;
    IF vw IS DISTINCT FROM 'A-14' THEN fails := fails || 'READ: view disagrees on re-read; '; END IF;
    steps := steps || 'READ ok; ';

    ----------------------------------------------------------------- UPDATE
    ret := client.update_property_operational(p_id, '{"lock_box_key":"C1709x"}'::jsonb);
    SELECT lock_box_key INTO col FROM public.properties WHERE id = p_id;
    SELECT lock_box_key INTO vw  FROM client.properties  WHERE id = p_id;
    IF col IS DISTINCT FROM 'C1709x' THEN fails := fails || 'UPDATE: base table kept the old value; '; END IF;
    IF vw  IS DISTINCT FROM 'C1709x' THEN fails := fails || 'UPDATE: view kept the old value; '; END IF;
    steps := steps || 'UPDATE ok; ';

    ----------------------------------------------------------------- DELETE (blank it)
    ret := client.update_property_operational(p_id, '{"lock_box_key":""}'::jsonb);
    SELECT lock_box_key INTO col FROM public.properties WHERE id = p_id;
    SELECT lock_box_key INTO vw  FROM client.properties  WHERE id = p_id;
    IF col IS NOT NULL THEN
      fails := fails || format('DELETE: expected NULL, got %L - an empty string here is a second representation of "no lock box"; ', col);
    END IF;
    IF vw IS NOT NULL THEN fails := fails || 'DELETE: the view still shows a value; '; END IF;
    steps := steps || 'DELETE ok; ';

    ----------------------------------------------------------------- whitespace-only
    PERFORM client.update_property_operational(p_id, '{"lock_box_key":"A-14"}'::jsonb);
    PERFORM client.update_property_operational(p_id, '{"lock_box_key":"   "}'::jsonb);
    SELECT lock_box_key INTO col FROM public.properties WHERE id = p_id;
    IF col IS NOT NULL THEN fails := fails || format('WHITESPACE: stored %L instead of NULL; ', col); END IF;
    steps := steps || 'WHITESPACE ok; ';

    ----------------------------------------------------------------- the guards refuse
    BEGIN
      PERFORM client.update_property_operational(p_id, jsonb_build_object('lock_box_key', repeat('x', 101)));
      fails := fails || 'GUARD: a 101-character value was accepted; ';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
      PERFORM client.update_property_operational(p_id,
        jsonb_build_object('lock_box_key', 'A' || chr(10) || 'B'));
      fails := fails || 'GUARD: a control character was accepted; ';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    steps := steps || 'GUARDS ok; ';

    ----------------------------------------------------------------- untouched neighbours
    -- The patch carries one key. If the RPC ever rebuilt the whole row, the fields the modal
    -- did not send would be cleared, which is the failure this asserts against.
    SELECT count(*) INTO n FROM public.properties
     WHERE id = p_id AND (access_notes IS NOT NULL OR notes IS NOT NULL OR grease_trap_manhole_count IS NOT NULL);
    steps := steps || format('neighbours intact (%s populated); ', n);

  EXCEPTION WHEN others THEN
    -- restore before re-raising, so a failed run does not leave the subject dirty
    UPDATE public.properties SET lock_box_key = started WHERE id = p_id;
    RAISE EXCEPTION 'SMOKE ABORTED after [%]: % (subject restored to %)', steps, SQLERRM, coalesce(started,'NULL');
  END;

  ----------------------------------------------------------------- restore
  UPDATE public.properties SET lock_box_key = started WHERE id = p_id;
  SELECT lock_box_key INTO col FROM public.properties WHERE id = p_id;
  IF col IS DISTINCT FROM started THEN
    fails := fails || format('RESTORE: subject left at %L, started at %L; ', col, started);
  END IF;

  IF fails <> '' THEN RAISE EXCEPTION 'SMOKE FAILED >>> % [ran: %]', fails, steps; END IF;
  RAISE EXCEPTION 'SMOKE PASSED >>> % (subject % restored to %)', steps, p_id, coalesce(started,'NULL');
END $smoke$;
`;

(async () => {
  // The DO block signals its verdict by RAISING, so both outcomes arrive here as an error
  // string. A silent success would be indistinguishable from a block that never ran.
  try {
    await sql(BODY);
    console.error('UNEXPECTED: the smoke block returned without raising a verdict.');
    process.exit(2);
  } catch (e) {
    const m = String(e.message);
    const trim = (x) => x.split(/\r?\nCONTEXT/)[0].trim();
    if (m.includes('SMOKE PASSED')) { console.log('PASS  ' + trim(m.split('SMOKE PASSED >>>')[1])); return; }
    console.error('FAIL  ' + trim(m));
    process.exit(1);
  }
})();
