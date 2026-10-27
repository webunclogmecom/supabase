// stamp_skip_sheet.mjs - the "skip a sheet with no scan" rules of Stamp Studio, on Prod, with NO lasting write.
//   node --env-file=.env scripts/checks/stamp_skip_sheet.mjs          (from Supabase/)
//   CONTROL=1 ... same, but the skip call is left out: the check must FAIL (proves the assertions bite)
// The rules (Trello EizZ2IuY, migration 2026-10-27_1640_stamp_skip_sheet_with_no_scan):
//   live  L1 a sheet counts as skipped only while it has no page and is not completed
//         L2 a skipped sheet is never in derm.fn_stamp_open_sheets (the 11 AM Slack post)
//         L3 a sheet has a missing-scan sentence exactly when it has no page
//   undone, on a [TEST] manifest of 112-YA (and on a real unskipped 0-page sheet when one exists):
//         R1 a new manifest with no photo makes a 0-page sheet: "No address sheet photo was uploaded"
//         R2 a manifest photo alone: "Only the manifest photo"; an address photo whose file is gone: "file is missing"
//         R3 skip -> skipped, with reason and person; a reason is required; "other" needs a note
//         R4 a stored address photo arrives -> 0 skipped, back to Not started BY ITSELF, missing sentence gone,
//            and skipping is refused ("This sheet has a scan")
//         R5 undo clears the skip
//         R6 (real 0-page sheet) skip removes it from the 11 AM list, undo puts it back
// Everything runs in ONE statement whose last step raises P0099 with the results, so the whole run is rolled back.
const sql = String.raw`
DO $c$
DECLARE r jsonb := '{}'; v_wm text := '99' || to_char(clock_timestamp(), 'HH24MISSUS'); v_f text; v_id bigint;
        v_img text; s record; v_msg text; v_real text; v_ctl boolean := ${process.env.CONTROL === '1' ? 'true' : 'false'};
BEGIN
  r := r || jsonb_build_object(
    'L1', NOT EXISTS (SELECT 1 FROM derm.v_stamp_sheets WHERE skipped AND (page_count > 0 OR completed)),
    'L2', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(derm.fn_stamp_open_sheets()) e
                        JOIN derm.v_stamp_sheets vs ON vs.white_manifest_number = e->>'manifest' WHERE vs.skipped),
    'L3', NOT EXISTS (SELECT 1 FROM derm.v_stamp_sheets WHERE (page_count = 0) IS DISTINCT FROM (missing_scan IS NOT NULL)));

  SELECT dump_folder INTO v_real FROM derm.v_stamp_sheets WHERE page_count = 0 AND NOT completed AND NOT skipped
   ORDER BY dump_folder LIMIT 1;
  SELECT m.derm_address_url INTO v_img FROM public.derm_manifests m
   WHERE m.deleted_at IS NULL AND m.derm_address_url IS NOT NULL AND derm._img_etag(m.derm_address_url) IS NOT NULL
   ORDER BY m.id DESC LIMIT 1;

  -- a white number is a Miami-Dade offload, so the facility is a Miami-Dade one (the filing rules require both)
  INSERT INTO public.derm_manifests (client_id, service_date, dump_ticket_date, white_manifest_number, disposal_facility_id, notes)
  VALUES ((SELECT id FROM public.clients WHERE client_code = '112-YA'), current_date, current_date, v_wm,
          (SELECT id FROM public.disposal_facilities WHERE county = 'Miami-Dade' ORDER BY id LIMIT 1),
          '[TEST] stamp_skip_sheet check, rolled back')
  RETURNING id INTO v_id;
  v_f := 'ticket-' || v_wm;
  SELECT * INTO s FROM derm.v_stamp_sheets WHERE dump_folder = v_f;
  r := r || jsonb_build_object('R1', s.page_count = 0 AND s.missing_scan LIKE 'No address sheet photo was uploaded%');

  UPDATE public.derm_manifests SET derm_manifest_url = v_img WHERE id = v_id;
  SELECT * INTO s FROM derm.v_stamp_sheets WHERE dump_folder = v_f;
  r := r || jsonb_build_object('R2a', s.missing_scan LIKE 'Only the manifest photo%');
  UPDATE public.derm_manifests SET derm_manifest_url = NULL, derm_address_url = v_img || '.gone' WHERE id = v_id;
  SELECT * INTO s FROM derm.v_stamp_sheets WHERE dump_folder = v_f;
  r := r || jsonb_build_object('R2b', s.page_count = 0 AND s.missing_scan LIKE '%its file is missing%');

  BEGIN PERFORM derm.set_sheet_skipped(v_f, true, NULL, NULL); v_msg := 'no refusal'; EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
  r := r || jsonb_build_object('R3_reason_required', v_msg = 'Pick why this sheet is skipped.');
  BEGIN PERFORM derm.set_sheet_skipped(v_f, true, 'other', '  '); v_msg := 'no refusal'; EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
  r := r || jsonb_build_object('R3_other_needs_note', v_msg = 'Write a short note saying why this sheet is skipped.');
  IF NOT v_ctl THEN PERFORM derm.set_sheet_skipped(v_f, true, 'record_only', 'check'); END IF;
  SELECT * INTO s FROM derm.v_stamp_sheets WHERE dump_folder = v_f;
  r := r || jsonb_build_object('R3', s.skipped AND s.skip_reason = 'record_only' AND s.skip_note = 'check'
                                     AND s.skipped_at IS NOT NULL AND s.skipped_by IS NOT NULL);

  UPDATE public.derm_manifests SET derm_address_url = v_img WHERE id = v_id;
  SELECT * INTO s FROM derm.v_stamp_sheets WHERE dump_folder = v_f;
  BEGIN PERFORM derm.set_sheet_skipped(v_f, true, 'record_only', NULL); v_msg := 'no refusal'; EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
  r := r || jsonb_build_object('R4', s.page_count = 1 AND NOT s.skipped AND s.missing_scan IS NULL AND s.skip_reason IS NULL
                                     AND v_msg = 'This sheet has a scan, so it cannot be skipped.');
  UPDATE public.derm_manifests SET derm_address_url = NULL WHERE id = v_id;
  SELECT * INTO s FROM derm.v_stamp_sheets WHERE dump_folder = v_f;
  r := r || jsonb_build_object('R4_scan_removed_skip_counts_again', s.skipped = NOT v_ctl);
  PERFORM derm.set_sheet_skipped(v_f, false);
  SELECT * INTO s FROM derm.v_stamp_sheets WHERE dump_folder = v_f;
  r := r || jsonb_build_object('R5', NOT s.skipped AND (SELECT skipped_at FROM derm.stamp_sheet_status WHERE dump_folder = v_f) IS NULL);

  IF v_real IS NOT NULL THEN
    IF NOT v_ctl THEN PERFORM derm.set_sheet_skipped(v_real, true, 'other', 'check'); END IF;
    r := r || jsonb_build_object('R6_skipped_leaves_list', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(derm.fn_stamp_open_sheets()) e
                                                             WHERE 'ticket-' || (e->>'manifest') = v_real));
    PERFORM derm.set_sheet_skipped(v_real, false);
    r := r || jsonb_build_object('R6_undo_returns', EXISTS (SELECT 1 FROM jsonb_array_elements(derm.fn_stamp_open_sheets()) e
                                                     WHERE 'ticket-' || (e->>'manifest') = v_real));
  END IF;
  r := r || jsonb_build_object('_real_sheet', v_real, '_photo_found', v_img IS NOT NULL);
  RAISE EXCEPTION USING ERRCODE = 'P0099', MESSAGE = 'RESULT ' || r::text;
END $c$;`
const res = await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', {
  method: 'POST', headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ query: sql }) })
const text = await res.text()
let msg = ''
try { msg = JSON.parse(text).message ?? '' } catch { /* not JSON: reported below */ }
const m = msg.match(/RESULT (\{.*\})/)   // the error message carries the results as one JSON line
if (!m) { console.log('UNKNOWN: no result came back:', text.slice(0, 400)); process.exit(2) }
const r = JSON.parse(m[1])
let bad = 0
for (const [k, v] of Object.entries(r)) {
  if (k.startsWith('_')) { console.log(`   ${k.padEnd(36)} ${v}`); continue }
  if (v !== true) bad++
  console.log(`${v === true ? 'PASS' : 'FAIL'} ${k}`)
}
if (!r._photo_found) { console.log('UNKNOWN: no stored address photo to use for R4'); process.exit(2) }
console.log(bad ? `${bad} FAILED${process.env.CONTROL === '1' ? ' (CONTROL: expected)' : ''}` : 'ALL PASS')
process.exit(bad ? 1 : 0)
