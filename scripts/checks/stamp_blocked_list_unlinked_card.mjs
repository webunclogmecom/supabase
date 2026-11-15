// stamp_blocked_list_unlinked_card.mjs - pick QQ as a rule (2026-11-15): a card with NO manifest link and NO stamp time,
// on a page with no measured extent, does not list its sheet in derm.v_blackout_blocked_sheets and does not make
// derm.fn_sheet_publishable answer 'needs_extent'. Migration 2026-11-15_1240_derm_blocked_list_skips_unlinked_unstamped_card.sql.
//   node --env-file=.env scripts/checks/stamp_blocked_list_unlinked_card.mjs          (from Supabase/)
//   CONTROL=1 ... same, but the OLD bodies are put back first (the rollback file, inside the same rolled-back transaction):
//                 A and D must FAIL, which proves the assertions bite.
// Fixtures in a folder that does not exist ('ticket-check-fixture-qq'), cards on page 1 of test ticket #111111 (it has one
// page, so its page 2 counts as never uploaded), client = the test manifest 2017's client; no extent for the folder:
//   A  an unlinked card with a stamp point, no stamp time: NOT listed, publishable (NULL).
//   B  a LINKED card (2017), stamp point, no stamp time: still listed and refused as 'no_stamp_timestamp'.
//   C  an unlinked card WITH a stamp time: still listed and refused as 'needs_extent'.
//   D  A plus a LINKED withheld card on page 2 (never uploaded): listed as 'cards_withheld' (with the arm-1 edit alone
//      no arm listed it; the two guards of arms 2 and 3 carry the same condition).
//   CITY the automatic city email for the test manifests 2017 and 2020 reads the same before and after.
// Everything runs in ONE request whose last step raises P0099 with the results, so the whole run is rolled back.
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const control = process.env.CONTROL === '1'
const rbFile = fileURLToPath(new URL('../../docs/migrations/2026-11-15_rollback_derm_blocked_list_skips_unlinked_unstamped_card.sql', import.meta.url))
const rb = control ? readFileSync(rbFile, 'utf8').replace(/\r\n/g, '\n').split('\nBEGIN;\n')[1].split('\nCOMMIT;')[0] : ''
if (control && !rb.includes('CREATE OR REPLACE VIEW derm.v_blackout_blocked_sheets')) { console.log('UNKNOWN: could not read the rollback body'); process.exit(2) }

const F = 'ticket-check-fixture-qq'
const card = (row, { mid = 'NULL', placed = 'NULL', page = 1 } = {}) => `
    INSERT INTO derm.address_row_map (dump_folder, white_manifest_number, page, row_index, image_url, assignment_status, source,
        matched_client_id, matched_manifest_id, stamp_x_pct, stamp_y_pct, stamp_page, stamp_placed_at, band_y0_pct, band_y1_pct, band_source)
    VALUES ('${F}', '111111', 1, ${row}, 'pending', 'matched', 'derm-link',
        (SELECT client_id FROM public.derm_manifests WHERE id = 2017), ${mid}, 9.6, 30, ${page}, ${placed}, 28, 32, 'manual');
    -- the generated-sheet autoplace (BEFORE INSERT) can place a linked card: put the fixture back as written
    UPDATE derm.address_row_map SET stamp_placed_at = ${placed}, stamp_page = ${page} WHERE dump_folder = '${F}' AND row_index = ${row};`

// shape: the cards as [mid is set, has a stamp time, effective page], so a fixture that did not land as written reads UNKNOWN
const fx = (key, cards, shape, expect) => `
DO $f$
DECLARE blk text; pub text; st text; ok boolean;
BEGIN
  BEGIN
    ${cards}
    SELECT string_agg((matched_manifest_id IS NOT NULL) || '/' || (stamp_placed_at IS NOT NULL) || '/' || COALESCE(stamp_page, page), ',' ORDER BY row_index)
      INTO st FROM derm.address_row_map WHERE dump_folder = '${F}';
    SELECT string_agg(blocker, ',') INTO blk FROM derm.v_blackout_blocked_sheets WHERE dump_folder = '${F}';
    pub := derm.fn_sheet_publishable('${F}');
    ok := ${expect === null ? 'blk IS NULL AND pub IS NULL' : `blk = '${expect}' AND pub = '${expect}'`};
    RAISE EXCEPTION USING ERRCODE = 'P0098', MESSAGE = 'undo';
  EXCEPTION WHEN SQLSTATE 'P0098' THEN NULL;
  END;
  INSERT INTO _res VALUES ('${key}', jsonb_build_object('ok', ok, 'as_written', st = '${shape}', 'listed', blk, 'publishable', pub));
END $f$;`

const city = k => `INSERT INTO _res SELECT '${k}', jsonb_build_object(
  'c', (SELECT jsonb_agg(jsonb_build_array(manifest_id, status) ORDER BY manifest_id) FROM derm.v_city_email_candidates WHERE manifest_id IN (2017, 2020)),
  'sends', (SELECT count(*) FROM public.derm_email_sends WHERE manifest_id IN (2017, 2020)));`

const sql = `BEGIN;
CREATE TEMP TABLE _res (k text PRIMARY KEY, v jsonb) ON COMMIT DROP;
INSERT INTO _res VALUES ('_fixture_free', to_jsonb(
  NOT EXISTS (SELECT 1 FROM derm.address_row_map WHERE dump_folder = '${F}')
  AND NOT EXISTS (SELECT 1 FROM derm.page_block_extents WHERE dump_folder = '${F}')
  AND NOT derm.fn_card_page_missing('111111', 1) AND derm.fn_card_page_missing('111111', 2)));
${city('_city_before')}
${rb}
${fx('A unlinked, no stamp time, unmeasured page: not listed, publishable', card(1), 'false/false/1', null)}
${fx('B LINKED, no stamp time, unmeasured page: still no_stamp_timestamp', card(1, { mid: 2017 }), 'true/false/1', 'no_stamp_timestamp')}
${fx('C unlinked WITH a stamp time, unmeasured page: still needs_extent', card(1, { placed: 'now()' }), 'false/true/1', 'needs_extent')}
${fx('D A plus a LINKED withheld card on a page never uploaded: cards_withheld', card(1) + card(2, { mid: 2017, page: 2 }), 'false/false/1,true/false/2', 'cards_withheld')}
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
if (!r._fixture_free) { console.log(`UNKNOWN: ${F} is in use, or #111111 no longer has exactly one page`); process.exit(2) }
let bad = 0
for (const [k, v] of Object.entries(r)) {
  if (k.startsWith('_')) continue
  if (!v.as_written) { console.log(`UNKNOWN ${k}: the fixture did not land as written`); process.exit(2) }
  if (v.ok !== true) bad++
  console.log(`${v.ok === true ? 'PASS' : 'FAIL'} ${k} (listed ${v.listed ?? 'no'}, publishable ${v.publishable ?? 'yes'})`)
}
const cityOk = JSON.stringify(r._city_before) === JSON.stringify(r._city_after)
if (!cityOk) bad++
console.log(`${cityOk ? 'PASS' : 'FAIL'} CITY the city email of the test manifests did not move`)
console.log(bad ? `${bad} FAILED${control ? ' (CONTROL: expected, the old bodies list A and D as no_stamp_timestamp)' : ''}` : 'ALL PASS')
process.exit(bad ? 1 : 0)
