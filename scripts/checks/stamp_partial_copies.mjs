// stamp_partial_copies.mjs - pick F (a sheet with an unstamped card still gives its SAFE stamped clients their copies),
// on Prod, with NO lasting write. Migration 2026-11-14_1300_derm_partial_copies_on_saved_rows.sql.
//   node --env-file=.env scripts/checks/stamp_partial_copies.mjs          (from Supabase/)
//   CONTROL=1 ... same, but the OLD bodies are put back first (the rollback file, inside the same rolled-back
//                 transaction): F1 must FAIL (the old gate freezes the whole folder), which proves the assertions bite.
// Fixtures on test ticket #111111 (test client; one page, 5 saved rows, manifest 2017 stamped in row 1, its copy row
// deleted inside the transaction so a target is due):
//   F1  one unstamped card added: NOT frozen, Mark completed goes through and queues one sweep kick, ONE target for 2017,
//       and THE PRIVACY PROOF on the geometry the copy maker reads: every saved row of the page that holds no 2017 card
//       (where the unstamped client is printed) lies inside the black area and outside the shown band.
//   F1b the same, with the stamped card's band_source set to an older value: frozen ('frozen_closed_world'), 0 targets.
//   F2  2017 also stamped in row 3, and an unstamped card: frozen, 0 targets (the shown span would hold row 2, where
//       the unstamped client can be printed).
//   F3  no unstamped card, 2017 stamped in rows 1 and 3, a WITHHELD card (a stamp point, no placement time) in row 2,
//       the sheet completed again: 0 targets (migration 2026-11-14_1308: the foreign-band exclusion counts every card
//       with a stamp point; before it, the copy showed 23.882..47.255 with the withheld row inside).
//   CITY the automatic city email for the test manifests 2017 and 2020 reads the same before and after.
// CONTROL=1 restores the bodies before pick F, which also predate 1308, so F1 and F3 must FAIL.
// Everything runs in ONE request whose last step raises P0099 with the results, so the whole run is rolled back.
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const control = process.env.CONTROL === '1'
const rbFile = fileURLToPath(new URL('../../docs/migrations/2026-11-14_rollback_derm_partial_copies_on_saved_rows.sql', import.meta.url))
const rb = control ? readFileSync(rbFile, 'utf8').replace(/\r\n/g, '\n').split('\nBEGIN;\n')[1].split('\nCOMMIT;')[0] : ''
if (control && !rb.includes('CREATE OR REPLACE VIEW derm.v_blackout_blocked_sheets')) { console.log('UNKNOWN: could not read the rollback body'); process.exit(2) }

const fixture = (extraRow3, olderSource, withheldRow2) => `
    ${withheldRow2 ? `INSERT INTO derm.address_row_map (dump_folder, white_manifest_number, page, row_index, image_url, assignment_status, source,
        matched_client_id, stamp_x_pct, stamp_y_pct, stamp_page, stamp_placed_at, band_y0_pct, band_y1_pct, band_source, slot_index)
      SELECT 'ticket-111111', '111111', 1, 92, 'pending', 'matched', 'derm-link', c.matched_client_id, 9.6, (s.y0_pct + s.y1_pct) / 2, 1, NULL,
             round(s.y0_pct, 3), round(s.y1_pct, 3), 'slot', 2
        FROM derm.page_slots s, derm.address_row_map c
       WHERE s.dump_folder = 'ticket-111111' AND s.effective_page = 1 AND s.slot_index = 2 AND c.id = 3051;` : `
    INSERT INTO derm.address_row_map (dump_folder, white_manifest_number, page, row_index, image_url, assignment_status, source, matched_client_id)
    VALUES ('ticket-111111', '111111', 1, 90, 'pending', 'unmatched', 'derm-link', (SELECT id FROM public.clients WHERE client_code = '112-YA'));`}
    ${extraRow3 ? `INSERT INTO derm.address_row_map (dump_folder, white_manifest_number, page, row_index, image_url, assignment_status, source,
        matched_client_id, matched_manifest_id, stamp_x_pct, stamp_y_pct, stamp_page, stamp_placed_at, band_y0_pct, band_y1_pct, band_source, slot_index)
      SELECT 'ticket-111111', '111111', 1, 91, 'pending', 'matched', 'derm-link', c.matched_client_id, 2017, 9.6,
             (s.y0_pct + s.y1_pct) / 2, 1, now(), round(s.y0_pct, 3), round(s.y1_pct, 3), 'slot', 3
        FROM derm.page_slots s, derm.address_row_map c
       WHERE s.dump_folder = 'ticket-111111' AND s.effective_page = 1 AND s.slot_index = 3 AND c.id = 3051;` : ''}
    ${olderSource ? `UPDATE derm.address_row_map SET band_source = 'manual' WHERE id = 3051;` : ''}`

const fx = (key, extraRow3, olderSource, expect, withheldRow2 = false) => `
DO $f$
DECLARE c boolean; q0 int; q1 int; blk text; pub text; n int; y0 numeric; y1 numeric; bt numeric; bb numeric; leak int; ok boolean;
BEGIN
  BEGIN
    ${fixture(extraRow3, olderSource, withheldRow2)}
    SELECT count(*) INTO q0 FROM net.http_request_queue;
    UPDATE derm.stamp_sheet_status SET completed = false WHERE dump_folder = 'ticket-111111';
    UPDATE derm.stamp_sheet_status SET completed = true WHERE dump_folder = 'ticket-111111';
    SELECT completed INTO c FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-111111';
    SELECT count(*) INTO q1 FROM net.http_request_queue;
    SELECT blocker INTO blk FROM derm.v_blackout_blocked_sheets WHERE dump_folder = 'ticket-111111';
    pub := derm.fn_sheet_publishable('ticket-111111');
    DELETE FROM derm.redacted_manifest_docs WHERE manifest_id = 2017;
    SELECT count(*) INTO n FROM derm.fn_blackout_targets(100000) t WHERE t.ticket_key = '111111';
    SELECT t.band_y0, t.band_y1, t.blocks_top, t.blocks_bottom INTO y0, y1, bt, bb
      FROM derm.fn_blackout_targets(100000) t WHERE t.manifest_id = 2017 LIMIT 1;
    SELECT count(*) INTO leak FROM derm.page_slots s
     WHERE s.dump_folder = 'ticket-111111' AND s.effective_page = 1
       AND NOT EXISTS (SELECT 1 FROM derm.address_row_map o WHERE o.dump_folder = 'ticket-111111' AND o.matched_manifest_id = 2017
                         AND o.stamp_y_pct IS NOT NULL AND o.band_y0_pct = round(s.y0_pct, 3) AND o.band_y1_pct = round(s.y1_pct, 3))
       AND (s.y0_pct < y1 AND s.y1_pct > y0 OR s.y0_pct < bt OR s.y1_pct > bb);
    ok := ${expect === 'released'
      ? `c AND q1 - q0 = 1 AND blk IS NULL AND pub IS NULL AND n = 1 AND y0 IS NOT NULL AND leak = 0
         AND (SELECT count(*) FROM derm.page_slots WHERE dump_folder = 'ticket-111111' AND effective_page = 1) >= 3`
      : expect === 'dropped'
      ? `c AND n = 0`
      : `NOT c AND q1 = q0 AND blk = 'frozen_closed_world' AND pub = 'frozen_closed_world' AND n = 0`};
    RAISE EXCEPTION USING ERRCODE = 'P0098', MESSAGE = 'undo';
  EXCEPTION WHEN SQLSTATE 'P0098' THEN NULL;
  END;
  INSERT INTO _res VALUES ('${key}', to_jsonb(ok));
END $f$;`

const city = k => `INSERT INTO _res SELECT '${k}', jsonb_build_object(
  'c', (SELECT jsonb_agg(jsonb_build_array(manifest_id, status) ORDER BY manifest_id) FROM derm.v_city_email_candidates WHERE manifest_id IN (2017, 2020)),
  'sends', (SELECT count(*) FROM public.derm_email_sends WHERE manifest_id IN (2017, 2020)));`

const sql = `BEGIN;
CREATE TEMP TABLE _res (k text PRIMARY KEY, v jsonb) ON COMMIT DROP;
INSERT INTO _res VALUES ('_fixture_as_written', to_jsonb(
  (SELECT array_agg(slot_index ORDER BY slot_index) FROM derm.page_slots WHERE dump_folder = 'ticket-111111' AND effective_page = 1) = ARRAY[1,2,3,4,5]
  AND EXISTS (SELECT 1 FROM derm.address_row_map WHERE id = 3051 AND dump_folder = 'ticket-111111' AND matched_manifest_id = 2017
                AND stamp_placed_at IS NOT NULL AND band_source = 'slot' AND slot_index = 1)
  AND (SELECT count(*) FROM derm.address_row_map WHERE dump_folder = 'ticket-111111') = 1));
${city('_city_before')}
${rb}
${fx('F1 one unstamped card: the stamped client gets its copy, and only its own row shows', false, false, 'released')}
${fx('F1b the stamped card is not in a saved row: frozen', false, true, 'frozen')}
${fx('F2 client stamped in rows 1 and 3, unstamped card: frozen (row 2 would show)', true, false, 'frozen')}
${fx('F3 client stamped in rows 1 and 3, a WITHHELD card in row 2: no copy made (row 2 would show)', true, false, 'dropped', true)}
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
if (!m) { console.log('UNKNOWN: no result came back:', (msg || text).slice(0, 400)); process.exit(2) }
const r = JSON.parse(m[1])
if (!r._fixture_as_written) { console.log('UNKNOWN: #111111 is no longer the one-card, five-row sheet this fixture needs'); process.exit(2) }
let bad = 0
for (const [k, v] of Object.entries(r)) {
  if (k.startsWith('_')) continue
  if (v !== true) bad++
  console.log(`${v === true ? 'PASS' : 'FAIL'} ${k}`)
}
const cityOk = JSON.stringify(r._city_before) === JSON.stringify(r._city_after)
if (!cityOk) bad++
console.log(`${cityOk ? 'PASS' : 'FAIL'} CITY the city email of the test manifests did not move`)
console.log(bad ? `${bad} FAILED${control ? ' (CONTROL: expected, the old gate freezes F1 and the old exclusion shows F3\'s withheld row)' : ''}` : 'ALL PASS')
process.exit(bad ? 1 : 0)
