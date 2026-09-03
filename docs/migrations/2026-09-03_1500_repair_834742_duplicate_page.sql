-- 2026-09-03_1500_repair_834742_duplicate_page.sql
--
-- WHY
-- ---
-- Fred, looking at `ticket-834742` in the Stamp Studio: **"page 2 is a dupe of page 1, why? at the
-- DERM App we only have uploaded 2 pages, we need to get the source of this and fix it so it never
-- happens again."** He was right, and the source is a trigger, not the upload.
--
-- `derm.ticket_page_images('834742')` returns THREE entries built from TWO uploaded images:
--     [ .../derm/1776/address_1.jpg , .../derm/1776/address_1.jpg , .../derm/1776/address_2.jpg ]
-- because the function groups `derm.address_row_map` by `page` and takes `mode(image_url)` per
-- page, and ONE card claims `page = 2` while carrying page 1's image.
--
-- ROOT CAUSE (measured, not inferred)
-- -----------------------------------
-- `derm.trg_autoplace_generated` executes `NEW.page := v_img;` where `v_img` is the IMAGE POSITION
-- returned by `fn_sheet_image_position`, and never sets a matching `NEW.image_url`. A catalogue
-- sweep over every non-catalog function shows it is the ONLY object in the database that assigns
-- `NEW.page` (positive control: the same regex matches this function; negative control: it does not
-- match `fn_reconcile_stamp_pages`).
--
-- The card is `id = 1106`, written 2026-09-03 12:20:39.760048 ET in txid 2989557 through
-- `public.file_manifest` (audit id 180555, app_source 'derm-tracker', contact@unclogme.com):
--   manifest 1785 = slot 8 of generated sheet 146
--   -> fn_generated_row_geometry(8) -> o_page = ((8-1)/5)+1 = 2
--   -> fn_sheet_image_position('ticket-834742', 2) returned the IDENTITY 2, because
--      `derm.address_sheet_scan_reads` held ZERO rows at that instant (the OCR sweep wrote its two
--      rows 9m24s later). The same call returns NULL today.
--   -> NEW.page := 2 while image_url stayed 'address_1.jpg'  <- the corruption
-- 248 ms later `fn_reconcile_stamp_pages` correctly chased it: the array was now length 3, so the
-- five cards whose witness is `address_2.jpg` moved `stamp_page` 2 -> 3.
--
-- 🛑 This is a RECURRING generator, not a one-off. The identical code path produced `ticket-833049`
-- card 972 on 2026-08-17. Across the whole audit history, `trg_autoplace_generated` has written a
-- `page > 1` row exactly twice and BOTH are corrupt: **0 of 2 correct.** Estate-wide the defect is
-- exactly those two folders (18 rows of 726); the other 17 multi-page folders are legitimate, every
-- one with n_pages == n_distinct_images.
--
-- => THE SOURCE FIX AND THE PERMANENT GUARD ARE A SEPARATE MIGRATION, `2026-09-03_1510`. This one
--    repairs the data only. Apply them in that order: the guard is written to accept the repaired
--    folder, and applying it first would make this repair the only write able to clear it.
--
-- WHY IT IS SAFE TO REPAIR THIS FOLDER AND NOT `ticket-833049`
-- -----------------------------------------------------------
--   * `ticket-834742` serves **0 redacted documents** (control: the ledger holds 667 overall), so
--     no client is being shown anything today and nothing has to be withdrawn first.
--   * Its ten witnesses (`stamp_image_url`) were captured LIVE today, after the 2026-08-24 witness
--     install, so they are genuine evidence. `ticket-833049`'s were BACKFILLED from each stamp's own
--     ordinal on 2026-08-24 and are therefore circular - which is why that folder is frozen by
--     `page_block_extents_no_ticket_833049` and stays frozen. Do NOT copy this migration onto it;
--     its documented one-line fix DOUBLES the exposure from 5 clients to 10.
--
-- WHAT THIS CHANGES
--   P1  card 1106  page 2 -> 1                      (collapses the image list 3 -> 2)
--   P2  fn_reconcile_stamp_pages('834742')          (5 ordinals 3 -> 2, FROM THE WITNESS)
--   P3  page_row_rules   effective_page 3 -> 2      (14 rows)
--       page_rule_scans  effective_page 3 -> 2      (1 row)
--   P4  address_sheet_scan_reads  page 2            (1 row DELETED)
--
-- 🛑 P4 IS A DELETE ON AN UNAUDITED TABLE. `derm.address_sheet_scan_reads` carries no triggers, so
-- there is no `audit.logs.old_row` to restore from. The full pre-image is backed up to
-- `backups/2026-09-03_ticket-834742_pre_repair.json` (gitignored), and the restore statement is in
-- the ROLLBACK block at the foot of this file.
-- WHY it must go rather than be re-pointed: BOTH scan reads name `address_1.jpg`. The page=2 read
-- was taken THROUGH the duplicate - it read imgs[2], which was the second copy of address_1, and
-- unsurprisingly read '1106-1' again. After the repair imgs[2] IS address_2, so that row would
-- assert "image position 2 is sheet 1106-1", which is false, and `fn_sheet_image_position` treats
-- its reads as a CLOSED map. A false entry there places stamps on the wrong scan.
--
-- 🛑 WHAT THIS DELIBERATELY DOES NOT DO
--   * It does NOT add a page-2 extent and does NOT snap the page-2 bands. All five page-2 cards
--     still carry DERIVED bands. "An extent does not redact anything: it opens the gate onto
--     whatever bands already exist" - adding one here is the act that leaked client data on
--     2026-08-19. Snapping + extent is its own reviewed migration, AFTER the check below.
--   * It does NOT establish which physical sheet `address_2.jpg` is. The repair makes the ordinals
--     self-consistent with the witnesses; it does not adjudicate whether the witnesses are right.
--     `address_2.jpg` has never had its sheet number read, and there are zero row reads for this
--     folder, so **a person must open address_2.jpg and confirm clients 375, 57, 477, 279 and 341
--     are the ones printed on it** before any extent is added. The page-identity check inside
--     `fn_blackout_targets` is scoped to `source='claude-vision-v1'` and every card here is
--     `derm-link`, so it is INERT on this folder.
--   * It does NOT re-complete the sheet. `stamp_sheet_status` already reads completed=false /
--     reopened_at 2026-09-03 16:31:22Z, and P2 trips `trg_zz_dirty_on_card_change` anyway (a no-op
--     here). A person must re-complete it in the Studio, and the 2026-09-03_1230 gate will refuse
--     until the page-2 geometry exists - which is the correct order.
--   * It does NOT tidy card 1097's `image_url = 'pending'`. That column is documented as stale and
--     is excluded from `mode()` by `image_url <> 'pending'`, so it cannot affect the image list.
--     Writing address_2 there would be the exact mistake the invariant forbids: `page` is the OCR
--     page, not the page the stamp is on.
--
-- ISOLATION: deliberately NOT `REPEATABLE READ`. The Management API transport does not guarantee
-- this body is the first statement of its transaction, so `SET TRANSACTION ISOLATION LEVEL` could
-- silently fail to take. Every statement instead re-asserts its own predicate in its WHERE clause
-- and asserts ROW_COUNT, and VERIFY 6 fingerprints every card OUTSIDE this folder, which is the
-- stronger check anyway.
--
-- RULE 8 (audit): no table or column added. `derm.address_row_map` is already audited, so P1 and P2
-- are captured. `page_row_rules`, `page_rule_scans` and `address_sheet_scan_reads` are NOT audited
-- (machine-detector output, regenerable) - hence the JSON backup above.

BEGIN;

-- Pre-image for the no-collateral-damage assertion (VERIFY 6).
CREATE TEMP TABLE _pre_834742 ON COMMIT DROP AS
SELECT (SELECT md5(string_agg(id||':'||page||':'||coalesce(stamp_page,-1)||':'||coalesce(stamp_image_url,''), ',' ORDER BY id))
          FROM derm.address_row_map WHERE dump_folder <> 'ticket-834742') AS arm_other_fp,
       (SELECT count(*) FROM derm.page_row_rules           WHERE dump_folder <> 'ticket-834742') AS rules_other,
       (SELECT count(*) FROM derm.page_rule_scans          WHERE dump_folder <> 'ticket-834742') AS scans_other,
       (SELECT count(*) FROM derm.address_sheet_scan_reads WHERE dump_folder <> 'ticket-834742') AS reads_other,
       (SELECT count(*) FROM derm.page_block_extents)      AS extents_all,
       (SELECT count(*) FROM derm.redacted_manifest_docs)  AS docs_all;

-- ---------------------------------------------------------------------------
-- P0. PRECONDITIONS. Abort unless the folder is in the exact shape measured today.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE n int; v_imgs text[];
BEGIN
  SELECT count(*) INTO n FROM derm.address_row_map WHERE dump_folder = 'ticket-834742';
  IF n <> 10 THEN RAISE EXCEPTION 'P0a: expected 10 cards, found %', n; END IF;

  -- ticket_page_images keys on white_manifest_number, NOT dump_folder. Assert they coincide,
  -- or every statement below is scoped to a different set of rows than the function reads.
  SELECT count(*) INTO n FROM derm.address_row_map
   WHERE white_manifest_number = '834742' AND dump_folder <> 'ticket-834742';
  IF n <> 0 THEN RAISE EXCEPTION 'P0b: white# 834742 spans another folder (% rows)', n; END IF;

  -- fn_reconcile_stamp_pages is ALL-OR-NOTHING: one unwitnessed stamp and it silently returns 0.
  SELECT count(*) INTO n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-834742' AND (stamp_placed_at IS NULL OR stamp_image_url IS NULL);
  IF n <> 0 THEN RAISE EXCEPTION 'P0c: % card(s) unplaced or unwitnessed', n; END IF;

  -- the defect is still present (never "repair" a folder somebody already fixed)
  v_imgs := derm.ticket_page_images('834742');
  IF array_length(v_imgs, 1) <> 3 OR v_imgs[1] IS DISTINCT FROM v_imgs[2] THEN
    RAISE EXCEPTION 'P0d: image list is not the measured [a1,a1,a2] defect: %', v_imgs;
  END IF;

  -- nothing is served, so nothing can be mis-served by this change
  SELECT count(*) INTO n FROM derm.redacted_manifest_docs
   WHERE manifest_id IN (SELECT id FROM public.derm_manifests
                          WHERE COALESCE(white_manifest_number, yellow_ticket_number) = '834742');
  IF n <> 0 THEN
    RAISE EXCEPTION 'P0e: % document(s) already served - withdraw first, in the order extents -> bands -> docs', n;
  END IF;

  -- the destination ordinals are free
  SELECT count(*) INTO n FROM derm.page_row_rules  WHERE dump_folder='ticket-834742' AND effective_page = 2;
  IF n <> 0 THEN RAISE EXCEPTION 'P0f: page_row_rules already holds effective_page=2 (% rows)', n; END IF;
  SELECT count(*) INTO n FROM derm.page_rule_scans WHERE dump_folder='ticket-834742' AND effective_page = 2;
  IF n <> 0 THEN RAISE EXCEPTION 'P0g: page_rule_scans already holds effective_page=2 (% rows)', n; END IF;
  SELECT count(*) INTO n FROM derm.page_block_extents WHERE dump_folder='ticket-834742' AND effective_page <> 1;
  IF n <> 0 THEN RAISE EXCEPTION 'P0h: an extent exists outside effective_page=1 (% rows)', n; END IF;

  -- the natural key (dump_folder, page, row_index) the rogue card is about to move into
  SELECT count(*) INTO n FROM derm.address_row_map
   WHERE dump_folder='ticket-834742' AND page = 1 AND row_index = 10;
  IF n <> 0 THEN RAISE EXCEPTION 'P0i: natural key (ticket-834742,1,10) is occupied'; END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- P1. Normalise the rogue OCR page. `page` is the OCR page and is NOT the page the stamp is on;
--     every card on a folder shares one `page` and only `stamp_page` varies. Card 1106 is the sole
--     violator. This statement alone cannot move a band: effective_page = COALESCE(stamp_page,page)
--     and 1106's stamp_page is non-null, so `page` does not participate.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE n int;
BEGIN
  UPDATE derm.address_row_map
     SET page = 1
   WHERE dump_folder = 'ticket-834742'
     AND id = 1106
     AND page = 2                        -- re-assert
     AND stamp_page = 3                  -- re-assert
     AND white_manifest_number = '834742';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'P1: updated % row(s), expected exactly 1', n; END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- P2. Put every ordinal back FROM THE WITNESS. Never hand-write stamp_page = 2: the witness is the
--     independent oracle and hand arithmetic would confirm itself.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_moved int;
BEGIN
  v_moved := derm.fn_reconcile_stamp_pages('834742');
  IF v_moved <> 5 THEN RAISE EXCEPTION 'P2: reconcile moved % ordinal(s), expected exactly 5', v_moved; END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- P3. The printed-rule detections are keyed on effective_page, which just moved 3 -> 2. Left at 3
--     they are orphans, and the page-2 bands could then never be snapped onto a detected rule -
--     which is the ONLY check that fails on derived bands (2026-08-19).
-- ---------------------------------------------------------------------------
DO $do$
DECLARE n int;
BEGIN
  UPDATE derm.page_row_rules SET effective_page = 2
   WHERE dump_folder = 'ticket-834742' AND effective_page = 3;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 14 THEN RAISE EXCEPTION 'P3a: moved % rule row(s), expected 14', n; END IF;

  UPDATE derm.page_rule_scans SET effective_page = 2
   WHERE dump_folder = 'ticket-834742' AND effective_page = 3
     AND source_url LIKE '%/derm/1776/address_2.jpg';   -- re-assert it is the address_2 scan
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'P3b: moved % scan row(s), expected 1', n; END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- P4. Withdraw the sheet-number read taken THROUGH the duplicate (see the header).
-- ---------------------------------------------------------------------------
DO $do$
DECLARE n int;
BEGIN
  DELETE FROM derm.address_sheet_scan_reads
   WHERE dump_folder = 'ticket-834742'
     AND page = 2
     AND image_url LIKE '%/derm/1776/address_1.jpg';    -- re-assert it read the DUPLICATE
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'P4: deleted % read(s), expected exactly 1', n; END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_a1 text := 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1776/address_1.jpg';
  v_a2 text := 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1776/address_2.jpg';
  v_imgs text[]; n int; p record;
BEGIN
  v_imgs := derm.ticket_page_images('834742');

  -- 1. THE SYMPTOM FRED REPORTED: 3 entries -> 2, in order, no duplicate.
  IF v_imgs IS DISTINCT FROM ARRAY[v_a1, v_a2] THEN
    RAISE EXCEPTION 'VERIFY 1: image list is %, expected [address_1, address_2]', v_imgs;
  END IF;
  IF (SELECT count(DISTINCT u) FROM unnest(v_imgs) u) <> 2 THEN
    RAISE EXCEPTION 'VERIFY 1b: a duplicate survives in the image list';
  END IF;

  -- 2. THE ONE THAT MATTERS: every stamp still resolves to the image it was PLACED on.
  SELECT count(*) INTO n FROM derm.address_row_map a
   WHERE a.dump_folder = 'ticket-834742'
     AND (a.stamp_page IS NULL
          OR a.stamp_page > array_length(v_imgs, 1)
          OR v_imgs[a.stamp_page] IS DISTINCT FROM a.stamp_image_url);
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 2: % card(s) no longer resolve to their witnessed image', n; END IF;
  SELECT count(*) INTO n FROM derm.address_row_map WHERE dump_folder='ticket-834742';
  IF n <> 10 THEN RAISE EXCEPTION 'VERIFY 2b: card count is %, expected 10', n; END IF;

  -- 2c. MUTATION CONTROL. If the two images were indistinguishable, VERIFY 2 would pass whatever
  --     ordinal each stamp carried - i.e. it would be vacuous. Prove it can fail.
  IF v_a1 = v_a2 OR v_imgs[1] = v_imgs[2] THEN
    RAISE EXCEPTION 'VERIFY 2c: control failed - the two images are identical, so VERIFY 2 proves nothing';
  END IF;
  SELECT count(*) INTO n FROM derm.address_row_map
   WHERE dump_folder='ticket-834742' AND stamp_image_url = v_a2;
  IF n <> 5 THEN RAISE EXCEPTION 'VERIFY 2d: control - expected 5 address_2 witnesses, found %', n; END IF;

  -- 3. The page-1 roster and its measured geometry are UNTOUCHED.
  SELECT count(*) INTO n FROM derm.address_row_map
   WHERE dump_folder='ticket-834742' AND COALESCE(stamp_page, page) = 1;
  IF n <> 5 THEN RAISE EXCEPTION 'VERIFY 3a: effective_page 1 holds % cards, expected 5', n; END IF;
  SELECT count(*) INTO n FROM derm.address_row_map
   WHERE dump_folder='ticket-834742' AND COALESCE(stamp_page, page) = 1
     AND id IN (1098, 1099, 1100, 1103, 1104);
  IF n <> 5 THEN RAISE EXCEPTION 'VERIFY 3b: the page-1 roster changed identity (% of 5)', n; END IF;
  SELECT count(*) INTO n FROM derm.address_row_map
   WHERE dump_folder='ticket-834742' AND COALESCE(stamp_page, page) = 2;
  IF n <> 5 THEN RAISE EXCEPTION 'VERIFY 3c: effective_page 2 holds % cards, expected 5', n; END IF;
  SELECT count(*) INTO n FROM derm.address_row_map
   WHERE dump_folder='ticket-834742' AND COALESCE(stamp_page, page) NOT IN (1, 2);
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 3d: % card(s) still sit on an ordinal outside {1,2}', n; END IF;
  SELECT count(DISTINCT page) INTO n FROM derm.address_row_map WHERE dump_folder='ticket-834742';
  IF n <> 1 THEN RAISE EXCEPTION 'VERIFY 3e: the folder still spans % OCR pages, expected 1', n; END IF;

  -- 3f/g/h. The page-1 extent still brackets its bands. <= / >=, NEVER equality: an empty printed
  --         slot makes a correct extent deliberately WIDER than the bands (the 2026-08-03 leak).
  SELECT * INTO p FROM (
    SELECT e.top_pct, e.bottom_pct, b.y0, b.y1
      FROM derm.page_block_extents e
      CROSS JOIN LATERAL (SELECT min(band_y0_pct) AS y0, max(band_y1_pct) AS y1
                            FROM derm.v_stamp_row_bands
                           WHERE dump_folder='ticket-834742' AND effective_page = 1) b
     WHERE e.dump_folder='ticket-834742' AND e.effective_page = 1) s;
  IF p IS NULL THEN RAISE EXCEPTION 'VERIFY 3f: the page-1 extent vanished'; END IF;
  IF NOT (p.top_pct <= p.y0 AND p.bottom_pct >= p.y1) THEN
    RAISE EXCEPTION 'VERIFY 3g: extent %/% no longer brackets bands %/%', p.top_pct, p.bottom_pct, p.y0, p.y1;
  END IF;
  IF (p.top_pct, p.bottom_pct) IS DISTINCT FROM (24.472, 64.042) THEN
    RAISE EXCEPTION 'VERIFY 3h: the extent itself moved to %/%', p.top_pct, p.bottom_pct;
  END IF;

  -- 4. All ten bands byte-identical to the values measured before the change. The five that move
  --    ordinal keep their derived values because v_stamp_row_bands partitions on effective_page and
  --    all five move together, but assert it rather than reason about it.
  SELECT count(*) INTO n FROM derm.v_stamp_row_bands
   WHERE dump_folder='ticket-834742'
     AND (id, band_y0_pct, band_y1_pct) IN (
       (1097, 25.840, 33.760), (1101, 55.925, 64.155), (1102, 48.145, 55.925),
       (1105, 33.760, 41.100), (1106, 41.100, 48.145),
       (1098, 40.541, 47.671), (1099, 47.671, 56.007), (1100, 56.007, 64.042),
       (1103, 24.472, 33.310), (1104, 33.310, 40.541));
  IF n <> 10 THEN RAISE EXCEPTION 'VERIFY 4: only % of 10 bands are unchanged', n; END IF;

  -- 5. The rules and the scan followed their page; no orphan ordinal survives.
  SELECT count(*) INTO n FROM derm.page_row_rules WHERE dump_folder='ticket-834742' AND effective_page = 2;
  IF n <> 14 THEN RAISE EXCEPTION 'VERIFY 5a: % page-2 rules, expected 14', n; END IF;
  SELECT count(*) INTO n FROM derm.page_row_rules WHERE dump_folder='ticket-834742' AND effective_page = 1;
  IF n <> 6  THEN RAISE EXCEPTION 'VERIFY 5b: % page-1 rules, expected 6', n; END IF;
  SELECT count(*) INTO n FROM derm.page_row_rules WHERE dump_folder='ticket-834742' AND effective_page NOT IN (1,2);
  IF n <> 0  THEN RAISE EXCEPTION 'VERIFY 5c: % orphan rule row(s) survive', n; END IF;
  SELECT count(*) INTO n FROM derm.page_rule_scans WHERE dump_folder='ticket-834742' AND effective_page NOT IN (1,2);
  IF n <> 0  THEN RAISE EXCEPTION 'VERIFY 5d: % orphan rule scan(s) survive', n; END IF;
  SELECT count(*) INTO n FROM derm.address_sheet_scan_reads WHERE dump_folder='ticket-834742';
  IF n <> 1  THEN RAISE EXCEPTION 'VERIFY 5e: % scan read(s), expected exactly 1', n; END IF;

  -- 5f. The map is now HONEST about what it does not know. Image position 2 has never been read,
  --     so fn_sheet_image_position must return NULL for printed page 2 and autoplace must refuse
  --     to place there. That NULL is the fail-closed behaviour, not a gap to fill.
  IF derm.fn_sheet_image_position('ticket-834742', 1) IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'VERIFY 5f: printed page 1 no longer maps to image position 1';
  END IF;
  IF derm.fn_sheet_image_position('ticket-834742', 2) IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY 5g: printed page 2 resolved to %, but address_2.jpg has never been read',
      derm.fn_sheet_image_position('ticket-834742', 2);
  END IF;

  -- 6. NO OTHER FOLDER CHANGED.
  SELECT * INTO p FROM _pre_834742;
  IF p.arm_other_fp IS DISTINCT FROM
       (SELECT md5(string_agg(id||':'||page||':'||coalesce(stamp_page,-1)||':'||coalesce(stamp_image_url,''), ',' ORDER BY id))
          FROM derm.address_row_map WHERE dump_folder <> 'ticket-834742')
    THEN RAISE EXCEPTION 'VERIFY 6a: cards outside ticket-834742 changed'; END IF;
  IF p.rules_other <> (SELECT count(*) FROM derm.page_row_rules           WHERE dump_folder <> 'ticket-834742')
    THEN RAISE EXCEPTION 'VERIFY 6b: page_row_rules changed outside this folder'; END IF;
  IF p.scans_other <> (SELECT count(*) FROM derm.page_rule_scans          WHERE dump_folder <> 'ticket-834742')
    THEN RAISE EXCEPTION 'VERIFY 6c: page_rule_scans changed outside this folder'; END IF;
  IF p.reads_other <> (SELECT count(*) FROM derm.address_sheet_scan_reads WHERE dump_folder <> 'ticket-834742')
    THEN RAISE EXCEPTION 'VERIFY 6d: address_sheet_scan_reads changed outside this folder'; END IF;
  IF p.extents_all <> (SELECT count(*) FROM derm.page_block_extents)
    THEN RAISE EXCEPTION 'VERIFY 6e: an extent was created or destroyed'; END IF;
  IF p.docs_all <> (SELECT count(*) FROM derm.redacted_manifest_docs)
    THEN RAISE EXCEPTION 'VERIFY 6f: a redacted document was published or withdrawn'; END IF;

  -- 7. Still serving nothing, and still gated.
  SELECT count(*) INTO n FROM derm.redacted_manifest_docs
   WHERE manifest_id IN (SELECT id FROM public.derm_manifests
                          WHERE COALESCE(white_manifest_number, yellow_ticket_number) = '834742');
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 7: % document(s) appeared for this folder', n; END IF;

  RAISE NOTICE 'VERIFY ok: ticket-834742 imgs=%, 10/10 witnesses resolve, page-1 geometry intact, page 2 honestly unread', v_imgs;
END $do$;

COMMIT;

-- ---------------------------------------------------------------------------
-- ROLLBACK (exact, and only exact because none of the statements above touch stamp_placed_at, so
-- `trg_ac_stamp_witness` never re-derives the witness). Valid while 0 documents are served.
-- ---------------------------------------------------------------------------
-- BEGIN;
-- UPDATE derm.address_row_map SET stamp_page = 3
--  WHERE dump_folder='ticket-834742' AND id IN (1097,1101,1102,1105,1106) AND stamp_page = 2;   -- 5
-- UPDATE derm.address_row_map SET page = 2
--  WHERE dump_folder='ticket-834742' AND id = 1106 AND page = 1;                                -- 1
-- UPDATE derm.page_row_rules  SET effective_page = 3 WHERE dump_folder='ticket-834742' AND effective_page = 2;  -- 14
-- UPDATE derm.page_rule_scans SET effective_page = 3 WHERE dump_folder='ticket-834742' AND effective_page = 2;  -- 1
-- INSERT INTO derm.address_sheet_scan_reads
--   (dump_folder, page, sheet_no_read, raw_read, confidence, model, image_url, read_at)
-- VALUES ('ticket-834742', 2, '1106-1', '1106-1', 'high', 'claude-sonnet-5',
--         'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1776/address_1.jpg',
--         '2026-09-03 16:30:05.576+00');
-- COMMIT;
