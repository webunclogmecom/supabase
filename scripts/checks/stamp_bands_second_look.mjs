// stamp_bands_second_look.mjs - pick J (a second look lets a PERSON save bands up to 40 percent uneven), on Prod,
// with NO lasting write. Migration 2026-11-14_1240_derm_bands_second_look.sql.
//   node --env-file=.env scripts/checks/stamp_bands_second_look.mjs          (from Supabase/)
//   CONTROL=1 ... same, but the OLD bodies are put back first (the rollback file, inside the same rolled-back
//                 transaction): the second-look case must FAIL, which proves the assertions bite.
// Fixture: test ticket #111111 page 1 (test client), its bands moved inside the transaction only. Each case runs as a
// signed-in Stamp editor (an active person whose Stamp Studio level is edit) with the Studio's header key, read from
// the live key function and never printed. The page's machine reference scans are deleted inside the transaction so
// only the validator decides.
//   C1 the old host's p_meta ({detail} only) at 27.5 percent uneven: refused with the uneven-spacing sentence
//   C2 second_look = true at 27.5 percent: saved, and page_rule_scans.detail says "saved after a second look by <person>"
//   C3 second_look = true at 45.9 percent: refused
//   C4 second_look = 'false' at 27.5 percent: refused
//   C5 a machine source (runlen-v2) with second_look at 27.5 percent: refused at 20 (written FAILED)
//   G  the validator: one function, grants authenticated + service_role only, IMMUTABLE, default 0.20
// Everything runs in ONE request whose last step raises P0099 with the results, so the whole run is rolled back.
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const control = process.env.CONTROL === '1'
const rbFile = fileURLToPath(new URL('../../docs/migrations/2026-11-14_rollback_derm_bands_second_look.sql', import.meta.url))
const rb = control ? readFileSync(rbFile, 'utf8').replace(/\r\n/g, '\n').split('\nBEGIN;\n')[1].split('\nCOMMIT;')[0] : ''
if (control && !rb.includes('DROP FUNCTION derm.fn_validate_page_rules(jsonb, numeric);')) {
  console.log('UNKNOWN: could not read the rollback body'); process.exit(2)
}

const lines = third => JSON.stringify([23.882, 32.588, third, 47.255, 55.412, 63.412].map(p => ({ pct: p, run: 1, ink: 1, kind: 'boundary' })))
const V25 = lines(38.5), V45 = lines(37.0)   // worst gap off the median: 27.5 and 45.9 percent
const HINT = 'Your bands are not evenly spaced down the page:%'
const SECOND = '{"detail":"check","second_look":true}'

const asCase = (key, rules, meta, expectSaved) => `
DO $c$
DECLARE st text; res jsonb; d text; out jsonb;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', (SELECT uid FROM _who), 'email', (SELECT email FROM _who), 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-stamp-key',
       substring(pg_get_functiondef('derm._require_stamp_key()'::regprocedure) from 'IS DISTINCT FROM ''([[:alnum:]_]+)'''))::text, true);
    SET LOCAL ROLE authenticated;
    BEGIN
      res := derm.save_page_bands('ticket-111111', 1, (SELECT url FROM _who), '${rules}'::jsonb, '${meta}'::jsonb);
      st := 'saved';
    EXCEPTION WHEN OTHERS THEN st := SQLERRM; END;
    RESET ROLE;
    SELECT detail INTO d FROM derm.page_rule_scans WHERE dump_folder = 'ticket-111111' AND effective_page = 1
       AND source = 'human-v1-' || to_char(now() AT TIME ZONE 'America/New_York', 'YYYY-MM-DD');
    out := to_jsonb(${expectSaved
      ? `st = 'saved' AND coalesce(d LIKE 'saved after a second look by ' || (SELECT email FROM _who) || ': every line is labelled a slot boundary, but they are not evenly pitched%', false)`
      : `st LIKE '${HINT}'`});
    RAISE EXCEPTION USING ERRCODE = 'P0098', MESSAGE = 'undo this case';
  EXCEPTION WHEN SQLSTATE 'P0098' THEN NULL;
  END;
  INSERT INTO _res VALUES ('${key}', out);
END $c$;`

const sql = `BEGIN;
CREATE TEMP TABLE _res (k text PRIMARY KEY, v jsonb) ON COMMIT DROP;
CREATE TEMP TABLE _who (uid uuid, email text, url text) ON COMMIT DROP;
GRANT SELECT ON _who TO authenticated;
DO $w$
DECLARE r record;
BEGIN
  FOR r IN SELECT u.id, u.email FROM public.employees e JOIN auth.users u ON lower(btrim(u.email)) = lower(btrim(e.email))
            WHERE e.status = 'ACTIVE' AND u.email_confirmed_at IS NOT NULL ORDER BY (e.access_level = 'admin') DESC, e.id LOOP
    PERFORM set_config('request.jwt.claims', json_build_object('sub', r.id, 'email', r.email, 'role', 'authenticated')::text, true);
    IF hr.fn_app_level('stamp_studio') = 'edit' THEN INSERT INTO _who VALUES (r.id, r.email, (derm.ticket_page_images('111111'))[1]); EXIT; END IF;
  END LOOP;
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _res VALUES ('_editor_found', to_jsonb(EXISTS (SELECT 1 FROM _who)));
  -- the fixture's premise: page 1 of #111111 still has the rows of Fred's drag test (2026-11-15 12:17 ET, his line under
  -- row 1 at 34.352; until then 32.588), else UNKNOWN, not FAIL. The fixture's lines replace them inside the transaction.
  INSERT INTO _res VALUES ('_fixture_rows_as_written', to_jsonb(
    (SELECT array_agg(y0_pct ORDER BY slot_index) FROM derm.page_slots WHERE dump_folder = 'ticket-111111' AND effective_page = 1)
      = ARRAY[23.882, 34.352, 39.569, 47.255, 55.412]::numeric[]));
  DELETE FROM derm.page_row_rules WHERE dump_folder = 'ticket-111111' AND effective_page = 1 AND (source LIKE 'runlen-v2-%' OR source LIKE 'template-v1-%');
  DELETE FROM derm.page_rule_scans WHERE dump_folder = 'ticket-111111' AND effective_page = 1 AND (source LIKE 'runlen-v2-%' OR source LIKE 'template-v1-%');
END $w$;
${rb}
${asCase('C1 old host p_meta at 27.5 percent: refused', V25, '{"detail":"2 Limit bands and 4 client bands drawn by hand on the scan"}', false)}
${asCase('C2 second look at 27.5 percent: saved, person named', V25, SECOND, true)}
${asCase('C3 second look at 45.9 percent: refused', V45, SECOND, false)}
${asCase('C4 second_look false at 27.5 percent: refused', V25, '{"second_look":"false"}', false)}
DO $c$
DECLARE res jsonb; out jsonb;
BEGIN
  BEGIN
    res := derm.record_page_rules('ticket-111111', 1, 'runlen-v2-' || to_char(now() AT TIME ZONE 'America/New_York', 'YYYY-MM-DD'),
                                  (SELECT url FROM _who), '${V25}'::jsonb, '{"grade":"OK","second_look":true}'::jsonb, false);
    out := to_jsonb(NOT (res->>'wrote')::boolean AND res->>'grade' = 'FAILED' AND res->>'reject' LIKE '%not evenly pitched%');
    RAISE EXCEPTION USING ERRCODE = 'P0098', MESSAGE = 'undo this case';
  EXCEPTION WHEN SQLSTATE 'P0098' THEN NULL;
  END;
  INSERT INTO _res VALUES ('C5 machine source with second look: refused at 20', out);
END $c$;
INSERT INTO _res VALUES ('G validator: one, granted to authenticated + service_role only, IMMUTABLE, default 0.20', to_jsonb(
  CASE WHEN to_regprocedure('derm.fn_validate_page_rules(jsonb, numeric)') IS NULL THEN false ELSE
  (SELECT count(*) FROM pg_proc WHERE proname = 'fn_validate_page_rules' AND pronamespace = 'derm'::regnamespace) = 1
  AND EXISTS (SELECT 1 FROM pg_proc WHERE oid = to_regprocedure('derm.fn_validate_page_rules(jsonb, numeric)') AND provolatile = 'i')
  AND NOT has_function_privilege('anon', 'derm.fn_validate_page_rules(jsonb, numeric)', 'execute')
  AND NOT EXISTS (SELECT 1 FROM pg_proc p CROSS JOIN LATERAL aclexplode(p.proacl) a
                   WHERE p.oid = to_regprocedure('derm.fn_validate_page_rules(jsonb, numeric)') AND a.grantee = 0)
  AND has_function_privilege('authenticated', 'derm.fn_validate_page_rules(jsonb, numeric)', 'execute')
  AND derm.fn_validate_page_rules('${V25}'::jsonb) LIKE 'every line is labelled a slot boundary, but they are not evenly pitched%' END));
DO $f$ BEGIN RAISE EXCEPTION USING ERRCODE = 'P0099', MESSAGE = 'RESULT ' || (SELECT jsonb_object_agg(k, v) FROM _res)::text; END $f$;
ROLLBACK;`

const res = await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', {
  method: 'POST', headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ query: sql }) })
const text = await res.text()
let msg = ''
try { msg = JSON.parse(text).message ?? '' } catch { /* not JSON: reported below */ }
const m = msg.match(/RESULT (\{.*\})/)
if (!m) { console.log('UNKNOWN: no result came back:', (msg || text).slice(0, 400)); process.exit(2) }
const r = JSON.parse(m[1])
if (!r._editor_found) { console.log('UNKNOWN: no active Stamp editor to run the cases as'); process.exit(2) }
if (!r._fixture_rows_as_written) { console.log('UNKNOWN: #111111 page 1 no longer has the rows this fixture keeps; update the fixture lines'); process.exit(2) }
let bad = 0
for (const [k, v] of Object.entries(r)) {
  if (k.startsWith('_')) continue
  if (v !== true) bad++
  console.log(`${v === true ? 'PASS' : 'FAIL'} ${k}`)
}
console.log(bad ? `${bad} FAILED${control ? ' (CONTROL: expected, the old bodies refuse the second look)' : ''}` : 'ALL PASS')
process.exit(bad ? 1 : 0)
