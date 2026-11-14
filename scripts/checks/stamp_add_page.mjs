// stamp_add_page.mjs - Add a page (pick D, derm.add_sheet_page), on Prod, with NO lasting write.
// Migration 2026-11-14_1315_derm_add_sheet_page.sql.
//   node --env-file=.env scripts/checks/stamp_add_page.mjs          (from Supabase/)
//   CONTROL=1 ... same, but the function's page-order proof is cut out inside the transaction: P2 must FAIL (a picture
//                 whose address sorts first is then accepted and every page after it moves), which proves P2 bites.
// Fixture: test ticket #111112 (test client). Two storage object ROWS are made inside the transaction (no file is
// uploaded, nothing is left behind): one whose address sorts after every page, one whose address sorts before page 1.
// Every call runs as a signed-in Stamp editor with the Studio's header key (read from the live key function, never printed).
//   P1 lands last: the new picture is the last page, every earlier page and the stamp are unchanged, the sheet reopens
//   P2 nothing moves: a picture that would not land last is refused with the page-order sentence, and nothing is written
//   P3 duplicate refused: the ticket's own page 1 picture is refused "This sheet already has this picture."
//   CITY the automatic city email of the test manifests reads the same before and after
// Everything runs in ONE request whose last step raises P0099 with the results, so the whole run is rolled back.
const control = process.env.CONTROL === '1'
const URL0 = 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/'
const LAST = URL0 + 'derm/ticket-111112/page-2-check.jpg', FIRST = URL0 + 'derm/0000-check.jpg'
const PROOF = `IF cardinality(v_after) <> cardinality(v_before) + 1
     OR v_after[cardinality(v_after)] IS DISTINCT FROM p_url
     OR (cardinality(v_before) > 0 AND v_after[1:cardinality(v_before)] IS DISTINCT FROM v_before) THEN`

const asEditor = expr => `
    PERFORM set_config('request.jwt.claims', json_build_object('sub', (SELECT uid FROM _who), 'email', (SELECT email FROM _who), 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-stamp-key',
       substring(pg_get_functiondef('derm._require_stamp_key()'::regprocedure) from 'IS DISTINCT FROM ''([[:alnum:]_]+)'''))::text, true);
    SET LOCAL ROLE authenticated;
    BEGIN ${expr} st := 'ok'; EXCEPTION WHEN OTHERS THEN st := SQLERRM; END;
    RESET ROLE;
    PERFORM set_config('request.headers', '', true); PERFORM set_config('request.jwt.claims', '', true);`

const sql = `BEGIN;
CREATE TEMP TABLE _res (k text PRIMARY KEY, v jsonb) ON COMMIT DROP;
CREATE TEMP TABLE _who (uid uuid, email text) ON COMMIT DROP;
GRANT SELECT ON _who TO authenticated;
INSERT INTO _res SELECT '_city_before', jsonb_build_object('c', (SELECT jsonb_agg(jsonb_build_array(manifest_id, status) ORDER BY manifest_id) FROM derm.v_city_email_candidates WHERE manifest_id IN (2017, 2020)),
  'sends', (SELECT count(*) FROM public.derm_email_sends WHERE manifest_id IN (2017, 2020)));
DO $w$
DECLARE r record;
BEGIN
  FOR r IN SELECT u.id, u.email FROM public.employees e JOIN auth.users u ON lower(btrim(u.email)) = lower(btrim(e.email))
            WHERE e.status = 'ACTIVE' AND u.email_confirmed_at IS NOT NULL ORDER BY (e.access_level = 'admin') DESC, e.id LOOP
    PERFORM set_config('request.jwt.claims', json_build_object('sub', r.id, 'email', r.email, 'role', 'authenticated')::text, true);
    IF hr.fn_app_level('stamp_studio') = 'edit' THEN INSERT INTO _who VALUES (r.id, r.email); EXIT; END IF;
  END LOOP;
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _res VALUES ('_editor_found', to_jsonb(EXISTS (SELECT 1 FROM _who)));
  INSERT INTO _res VALUES ('_fixture_one_page', to_jsonb(cardinality(derm.ticket_page_images('111112')) = 1
                                                         AND EXISTS (SELECT 1 FROM derm.address_row_map WHERE id = 3054 AND dump_folder = 'ticket-111112')));
  INSERT INTO storage.objects (bucket_id, name, metadata) VALUES
    ('manifests', 'derm/ticket-111112/page-2-check.jpg', '{"eTag":"stamp-add-page-check-last"}'::jsonb),
    ('manifests', 'derm/0000-check.jpg', '{"eTag":"stamp-add-page-check-first"}'::jsonb);
  ${control ? `EXECUTE replace(pg_get_functiondef('derm.add_sheet_page(text, text)'::regprocedure), $p$${PROOF}$p$, 'IF false THEN');
  IF strpos(pg_get_functiondef('derm.add_sheet_page(text, text)'::regprocedure), 'IF false THEN') = 0 THEN RAISE EXCEPTION 'control edit did not apply'; END IF;` : ''}
END $w$;
DO $c$
DECLARE st text; res jsonb; b text[]; a text[]; c0 record; c1 record; m0 text; m1 text; done boolean; ok boolean;
BEGIN
  b := derm.ticket_page_images('111112');
  SELECT page, stamp_page, stamp_y_pct, band_y0_pct, band_y1_pct INTO c0 FROM derm.address_row_map WHERE id = 3054;
  BEGIN
    ${asEditor(`res := derm.add_sheet_page('ticket-111112', '${LAST}');`)}
    a := derm.ticket_page_images('111112');
    SELECT page, stamp_page, stamp_y_pct, band_y0_pct, band_y1_pct INTO c1 FROM derm.address_row_map WHERE id = 3054;
    SELECT completed INTO done FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-111112';
    ok := st = 'ok' AND cardinality(a) = cardinality(b) + 1 AND a[cardinality(a)] = '${LAST}' AND a[1:cardinality(b)] = b
          AND c1 IS NOT DISTINCT FROM c0 AND NOT done AND (res->>'page')::int = cardinality(a);
    RAISE EXCEPTION USING ERRCODE = 'P0098', MESSAGE = 'undo';
  EXCEPTION WHEN SQLSTATE 'P0098' THEN NULL;
  END;
  INSERT INTO _res VALUES ('P1 lands last: earlier pages and the stamp unchanged, the sheet reopens', to_jsonb(coalesce(ok, false)));
  ok := NULL;
  BEGIN
    SELECT string_agg(coalesce(derm_address_url, '') || '|' || coalesce(array_to_string(derm_address_extra_urls, ','), ''), ';' ORDER BY id) INTO m0
      FROM public.derm_manifests WHERE COALESCE(white_manifest_number, yellow_ticket_number) = '111112' AND deleted_at IS NULL;
    ${asEditor(`res := derm.add_sheet_page('ticket-111112', '${FIRST}');`)}
    a := derm.ticket_page_images('111112');
    SELECT string_agg(coalesce(derm_address_url, '') || '|' || coalesce(array_to_string(derm_address_extra_urls, ','), ''), ';' ORDER BY id) INTO m1
      FROM public.derm_manifests WHERE COALESCE(white_manifest_number, yellow_ticket_number) = '111112' AND deleted_at IS NULL;
    ok := st LIKE 'The picture could not be added as the last page%' AND a = b AND m1 = m0;
    RAISE EXCEPTION USING ERRCODE = 'P0098', MESSAGE = 'undo';
  EXCEPTION WHEN SQLSTATE 'P0098' THEN NULL;
  END;
  INSERT INTO _res VALUES ('P2 a picture that would not land last is refused and nothing moves', to_jsonb(coalesce(ok, false)));
  ok := NULL;
  BEGIN
    ${asEditor(`res := derm.add_sheet_page('ticket-111112', b[1]);`)}
    ok := st = 'This sheet already has this picture.';
    RAISE EXCEPTION USING ERRCODE = 'P0098', MESSAGE = 'undo';
  EXCEPTION WHEN SQLSTATE 'P0098' THEN NULL;
  END;
  INSERT INTO _res VALUES ('P3 the ticket''s own page 1 picture is refused', to_jsonb(coalesce(ok, false)));
END $c$;
INSERT INTO _res SELECT '_city_after', jsonb_build_object('c', (SELECT jsonb_agg(jsonb_build_array(manifest_id, status) ORDER BY manifest_id) FROM derm.v_city_email_candidates WHERE manifest_id IN (2017, 2020)),
  'sends', (SELECT count(*) FROM public.derm_email_sends WHERE manifest_id IN (2017, 2020)));
DO $z$ BEGIN RAISE EXCEPTION USING ERRCODE = 'P0099', MESSAGE = 'RESULT ' || (SELECT jsonb_object_agg(k, v) FROM _res)::text; END $z$;
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
if (!r._fixture_one_page) { console.log('UNKNOWN: #111112 is no longer the one-page sheet this fixture needs'); process.exit(2) }
let bad = 0
for (const [k, v] of Object.entries(r)) {
  if (k.startsWith('_')) continue
  if (v !== true) bad++
  console.log(`${v === true ? 'PASS' : 'FAIL'} ${k}`)
}
const cityOk = JSON.stringify(r._city_before) === JSON.stringify(r._city_after)
if (!cityOk) bad++
console.log(`${cityOk ? 'PASS' : 'FAIL'} CITY the city email of the test manifests did not move`)
console.log(bad ? `${bad} FAILED${control ? ' (CONTROL: expected, the page-order proof was cut out)' : ''}` : 'ALL PASS')
process.exit(bad ? 1 : 0)
