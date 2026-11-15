// stamp_slot_band_follows_row.mjs - Fred's "Follow the row" (2026-11-15): when a page's lines are saved
// (derm.save_page_bands), a card whose band was TAKEN FROM A ROW (band_source 'slot') takes the row its stamp sits in,
// like a card with no band; a band drawn by hand for one client stays as drawn. Migration
// 2026-11-15_1350_derm_save_page_bands_slot_band_follows_row.sql. On Prod, with NO lasting write.
//   node --env-file=.env scripts/checks/stamp_slot_band_follows_row.mjs          (from Supabase/)
//   CONTROL=1 ... same, but the OLD body is put back first (the rollback file, inside the same rolled-back transaction):
//                 S1 must FAIL (the old body keeps a 'slot' band where it was), which proves the assertions bite.
//   APPLY=1   ... the migration file's body runs first (the rehearsal before it is applied; with CONTROL=1, the migration
//                 then the rollback file).
// Fixture: test ticket #111111 page 1 (test client 112-YA; one page; card 3051 stamped in the top row). Each case gives
// card 3051 the band named below, then saves the page's lines through derm.save_page_bands as a signed-in Stamp editor
// with the Studio's header key (read from the live key function, never printed). The page's machine reference scans are
// deleted inside the transaction so only the lines sent here decide. Lines A move the line under the top row from
// 32.588 to 33.0 (the drag of Fred's test, kept under the 20 percent spacing rule); lines C move the top Limit to 31.0,
// below card 3051's stamp.
//   S1  a 'slot' band 23.882..32.588, lines A: saved, the band is the moved row 23.882..33.0, row number 1, still 'slot'
//   S2  a hand-drawn ('manual') band 23.882..32.588, lines A: saved, the band stays as drawn, no row number
//   S3  S1 plus a second card with a 'slot' band in row 2 whose stamp (32.8) falls in the moved top row: refused
//       (two stamps in one row), nothing written
//   S3b the same with the second card's band drawn by hand: refused the same way
//   S4  a 'slot' band, lines C (its stamp is above every new row): refused (stamp outside the new rows), nothing written
//   S5  S1 plus a hand-drawn band 32.588..39.569 below it (stamp 36): the moved row would overlap that band, so the save
//       is refused by the geometry guard (G7, no overlap), nothing written
//   S6  a 'slot' band already on its row (23.882..33.0, no row number) on a COMPLETED sheet, lines A: saved, the row
//       number comes back, the band is not written again and the sheet stays completed
//   After every case: no two stamped cards on the page have overlapping bands.
//   CITY the automatic city email for the test manifests 2017 and 2020 reads the same before and after.
// Everything runs in ONE request whose last step raises P0099 with the results, so the whole run is rolled back.
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const control = process.env.CONTROL === '1'
const apply = process.env.APPLY === '1'
const body = f => readFileSync(fileURLToPath(new URL(`../../docs/migrations/${f}`, import.meta.url)), 'utf8')
  .replace(/\r\n/g, '\n').split('\nBEGIN;\n')[1].split('\nCOMMIT;')[0]
const mig = apply ? body('2026-11-15_1350_derm_save_page_bands_slot_band_follows_row.sql') : ''
const rb = control ? body('2026-11-15_rollback_derm_save_page_bands_slot_band_follows_row.sql') : ''
if ((apply && !mig.includes('CREATE OR REPLACE FUNCTION derm.save_page_bands')) || (control && !rb.includes('CREATE OR REPLACE FUNCTION derm.save_page_bands'))) {
  console.log('UNKNOWN: could not read the migration or rollback body'); process.exit(2)
}

const lines = pcts => JSON.stringify(pcts.map(p => ({ pct: p, run: 1, ink: 1, kind: 'boundary' })))
const A = lines([23.882, 33.0, 39.569, 47.255, 55.412, 63.412])
const C = lines([31.0, 39.569, 47.255, 55.412, 63.412])
const META = '{"detail":"stamp_slot_band_follows_row check"}'

// a second stamped card on page 1 of #111111 (same test client, no manifest), inside the case only
const other = (y, y0, y1, src, k) => `
    INSERT INTO derm.address_row_map (dump_folder, white_manifest_number, page, row_index, image_url, assignment_status, source,
        matched_client_id, stamp_x_pct, stamp_y_pct, stamp_page, stamp_placed_at, band_y0_pct, band_y1_pct, band_source, slot_index)
      SELECT 'ticket-111111', '111111', 1, 93, 'pending', 'matched', 'derm-link', c.matched_client_id, 9.6, ${y}, 1, now(),
             ${y0}, ${y1}, '${src}', ${k}
        FROM derm.address_row_map c WHERE c.id = 3051;`

// expect: 'saved' | a blocker code. check: a SQL boolean over the card after the call (b0, b1, src, k, set_at, done)
const sc = (key, band, extra, rules, expect, check, completedFirst = false) => `
DO $c$
DECLARE st text := 'saved'; det text; b0 numeric; b1 numeric; src text; k int; set_at timestamptz; set0 timestamptz;
        done boolean; ov int; out jsonb;
BEGIN
  BEGIN
    UPDATE derm.address_row_map SET band_y0_pct = ${band[0]}, band_y1_pct = ${band[1]}, band_source = '${band[2]}',
           slot_index = ${band[3]}, band_set_at = now() - interval '1 day' WHERE id = 3051;
    ${extra}
    ${completedFirst ? `UPDATE derm.stamp_sheet_status SET completed = true WHERE dump_folder = 'ticket-111111';` : ''}
    SELECT band_set_at INTO set0 FROM derm.address_row_map WHERE id = 3051;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', (SELECT uid FROM _who), 'email', (SELECT email FROM _who), 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-stamp-key',
       substring(pg_get_functiondef('derm._require_stamp_key()'::regprocedure) from 'IS DISTINCT FROM ''([[:alnum:]_]+)'''))::text, true);
    SET LOCAL ROLE authenticated;
    BEGIN
      PERFORM derm.save_page_bands('ticket-111111', 1, (SELECT url FROM _who), '${rules}'::jsonb, '${META}'::jsonb);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS det = PG_EXCEPTION_DETAIL;
      st := coalesce(substring(det from 'blocker=([a-z_]+)'), 'error: ' || SQLERRM);
    END;
    RESET ROLE;
    SELECT band_y0_pct, band_y1_pct, band_source, slot_index, band_set_at INTO b0, b1, src, k, set_at FROM derm.address_row_map WHERE id = 3051;
    SELECT completed INTO done FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-111111';
    SELECT count(*) INTO ov FROM derm.address_row_map x JOIN derm.address_row_map y ON y.id < x.id
     WHERE x.dump_folder = 'ticket-111111' AND y.dump_folder = 'ticket-111111'
       AND coalesce(x.stamp_page, x.page) = 1 AND coalesce(y.stamp_page, y.page) = 1
       AND x.stamp_y_pct IS NOT NULL AND y.stamp_y_pct IS NOT NULL
       AND x.band_y0_pct < y.band_y1_pct AND y.band_y0_pct < x.band_y1_pct;
    out := jsonb_build_object('ok', st = '${expect}' AND ov = 0 AND (${check}), 'got', st, 'overlaps', ov,
                              'band', jsonb_build_array(b0, b1), 'source', src, 'row', k, 'completed', done,
                              'detail', CASE WHEN st <> 'saved' THEN left(det, 200) END);
    RAISE EXCEPTION USING ERRCODE = 'P0098', MESSAGE = 'undo this case';
  EXCEPTION WHEN SQLSTATE 'P0098' THEN NULL;
  END;
  INSERT INTO _res VALUES ('${key}', out);
END $c$;`

const SLOT = (y0, y1, k = 1) => [y0, y1, 'slot', k]
const city = k => `INSERT INTO _res SELECT '${k}', jsonb_build_object(
  'c', (SELECT jsonb_agg(jsonb_build_array(manifest_id, status) ORDER BY manifest_id) FROM derm.v_city_email_candidates WHERE manifest_id IN (2017, 2020)),
  'sends', (SELECT count(*) FROM public.derm_email_sends WHERE manifest_id IN (2017, 2020)));`

const sql = `BEGIN;
CREATE TEMP TABLE _res (k text PRIMARY KEY, v jsonb) ON COMMIT DROP;
CREATE TEMP TABLE _who (uid uuid, email text, url text) ON COMMIT DROP;
GRANT SELECT ON _who TO authenticated;
${city('_city_before')}
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
  -- the premise: #111111 is one page, its only card is 3051 (stamped on page 1 inside the top row of lines A and below
  -- the top Limit of lines C would cut), and its Limit is 23.882..63.412 (lines A keep it, so S6 reopens nothing by it)
  INSERT INTO _res VALUES ('_fixture_as_written', to_jsonb(
    coalesce(array_length(derm.ticket_page_images('111111'), 1), 0) = 1
    AND (SELECT count(*) FROM derm.address_row_map WHERE dump_folder = 'ticket-111111') = 1
    AND EXISTS (SELECT 1 FROM derm.address_row_map WHERE id = 3051 AND dump_folder = 'ticket-111111' AND coalesce(stamp_page, page) = 1
                  AND stamp_placed_at IS NOT NULL AND stamp_y_pct > 24 AND stamp_y_pct < 30.9)
    AND EXISTS (SELECT 1 FROM derm.page_block_extents WHERE dump_folder = 'ticket-111111' AND effective_page = 1
                  AND top_pct = 23.882 AND bottom_pct = 63.412)));
  DELETE FROM derm.page_row_rules WHERE dump_folder = 'ticket-111111' AND effective_page = 1 AND (source LIKE 'runlen-v2-%' OR source LIKE 'template-v1-%');
  DELETE FROM derm.page_rule_scans WHERE dump_folder = 'ticket-111111' AND effective_page = 1 AND (source LIKE 'runlen-v2-%' OR source LIKE 'template-v1-%');
END $w$;
${mig}
${rb}
${sc('S1 a slot band follows its moved row', SLOT(23.882, 32.588), '', A, 'saved', `b0 = 23.882 AND b1 = 33.0 AND src = 'slot' AND k = 1`)}
${sc('S2 a hand-drawn band stays as drawn', [23.882, 32.588, 'manual', 'NULL'], '', A, 'saved', `b0 = 23.882 AND b1 = 32.588 AND src = 'manual' AND k IS NULL`)}
${sc('S3 a slot card and another slot card in the same new row: refused', SLOT(23.882, 32.588), other(32.8, 32.588, 39.569, 'slot', 2), A, 'two_stamps_one_row', `b1 = 32.588`)}
${sc('S3b a slot card and a hand-drawn card in the same new row: refused', SLOT(23.882, 32.588), other(32.8, 32.588, 39.569, 'manual', 'NULL'), A, 'two_stamps_one_row', `b1 = 32.588`)}
${sc('S4 a slot card outside every new row: refused', SLOT(23.882, 32.588), '', C, 'stamp_outside_rows', `b1 = 32.588`)}
${sc('S5 a slot card that would follow into a hand-drawn band: refused', SLOT(23.882, 32.588), other(36, 32.588, 39.569, 'manual', 'NULL'), A, 'geometry_refused', `b1 = 32.588`)}
${sc('S6 a slot band already on its row: row number back, band not rewritten, sheet stays completed', SLOT(23.882, 33.0, 'NULL'), '', A, 'saved',
     `b0 = 23.882 AND b1 = 33.0 AND src = 'slot' AND k = 1 AND set_at = set0 AND done`, true)}
${city('_city_after')}
DO $z$ BEGIN RAISE EXCEPTION USING ERRCODE = 'P0099', MESSAGE = 'RESULT ' || (SELECT jsonb_object_agg(k, v) FROM _res)::text; END $z$;
ROLLBACK;`

const res = await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', {
  method: 'POST', headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ query: sql }) })
const text = await res.text()
let msg = ''
try { msg = JSON.parse(text).message ?? '' } catch { /* not JSON: reported below */ }
const m = msg.match(/RESULT (\{.*\})/)
if (!m) { console.log('UNKNOWN: no result came back:', (msg || text).slice(0, 600)); process.exit(2) }
const r = JSON.parse(m[1])
if (!r._editor_found) { console.log('UNKNOWN: no active Stamp editor to run the cases as'); process.exit(2) }
if (!r._fixture_as_written) { console.log('UNKNOWN: #111111 is no longer the one-page, one-card sheet with the Limit this fixture needs'); process.exit(2) }
let bad = 0
for (const [k, v] of Object.entries(r)) {
  if (k.startsWith('_')) continue
  if (v.ok !== true) bad++
  console.log(`${v.ok === true ? 'PASS' : 'FAIL'} ${k} (got ${v.got}, band ${JSON.stringify(v.band)} ${v.source} row ${v.row ?? '-'}, overlaps ${v.overlaps}${v.ok === true ? '' : ', ' + (v.detail ?? '')})`)
}
const cityOk = JSON.stringify(r._city_before) === JSON.stringify(r._city_after)
if (!cityOk) bad++
console.log(`${cityOk ? 'PASS' : 'FAIL'} CITY the city email of the test manifests did not move`)
console.log(bad ? `${bad} FAILED${control ? ' (CONTROL: expected, the old body keeps a slot band where it was and lets a second card share its row)' : ''}` : 'ALL PASS')
process.exit(bad ? 1 : 0)
