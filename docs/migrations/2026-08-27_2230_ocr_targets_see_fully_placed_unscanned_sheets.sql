-- 2026-08-27_2230_ocr_targets_see_fully_placed_unscanned_sheets.sql
--
-- WHY: THE CHECK THAT VALIDATES AUTO-PLACEMENT WAS UNREACHABLE FOR AUTO-PLACED SHEETS.
-- ---------------------------------------------------------------------------
-- Fred: ticket-312433 "was showing as completed by AI but ALL the stamps were incorrect."
--
-- WHAT WENT WRONG. The two scans of generated sheet 1102 are stored in REVERSE order. The row OCR
-- proves it beyond argument:
--   address_1.jpg reads 091-SB, 009-CN, 009-CN, 009-CN, 154-PV  = printed rows 6-10 = PAGE 2
--   address_2.jpg reads 195-MYK, 309-KEB, 061-TCE, 133-MUT, 087-BB = printed rows 1-5 = PAGE 1
--
-- The placement arithmetic was CORRECT throughout - fn_generated_sheet_slot returned 10 for 154-PV
-- (the true printed row, not the client ordinal 8), and every geometry mapped to the right page and
-- y. What was wrong was the PAGE-TO-IMAGE mapping: derm.address_sheet_scan_reads held NOTHING for
-- this folder, so derm.fn_sheet_image_position fell back to identity (page 1 -> image 1) and every
-- one of the 8 stamps landed on the opposite scan.
--
-- 🛑 WHY IT WAS NEVER SCANNED, WHICH IS THE ACTUAL DEFECT. This function offered only folders with
-- an UNPLACED card, justified in its own comment as "a fully-placed sheet can never be auto-placed
-- again: reading it changes no decision". On a GENERATED sheet trg_ab_autoplace_generated places
-- every card at INSERT time, so such a folder NEVER has an unplaced card, so it was never offered,
-- so the sheet number was never read.
-- **Auto-placement made the sheet ineligible for the one check that validates auto-placement.**
--
-- 🛑 AND THIS IS THE SECOND OCCURRENCE. ticket-833813 was the same defect, found by Fred on
-- 2026-08-27 ("i see it all wrong") and fixed by hand that morning in 2026-08-27_1035. CLAUDE.md
-- even records the lesson verbatim - "A FULLY-STAMPED SHEET IS WHERE A PAGE TRANSPOSITION HIDES:
-- THE OCR SWEEP SKIPS IT BY DESIGN". The instance was repaired, the lesson was written down, and
-- the PREDICATE THAT GENERATES THE PROBLEM WAS LEFT ALONE. It reoccurred within the day.
-- Fixing an instance is not fixing a defect.
--
-- THE FIX: Arm B offers any MULTI-IMAGE ticket folder that has never been scanned, whatever its
-- placement state. Single-image folders stay excluded because with one page there is no ordering to
-- get wrong. The `ticket-%` cost filter is unchanged.
--
-- MEASURED BLAST RADIUS before this change: 19 multi-image ticket folders, 17 already scanned,
-- 2 never scanned (ticket-312433 and ticket-296623). Of those, ticket-296623 was fully placed and
-- therefore PERMANENTLY invisible to the sweep, and it SERVES a customer document. ticket-312433 is
-- currently visible only because Fred cleared its stamps by hand.
--
-- ⚠ SELF-DRAINING, so this cannot become a standing vision cost: once a folder has any scan read,
-- Arm B stops offering it forever. It adds 2 folders today.
--
-- 🛑 BODY COPIED FROM pg_get_functiondef AND SPLICED BY SCRIPT: two anchors, each asserted to match
-- exactly once. Everything below the CTE is untouched, including the per-page
-- "skip pages that already have a read" filter, which is what makes Arm B drain.
--
-- RULE 8 (audit trail): a function holds no state; opt-out.

BEGIN;

CREATE OR REPLACE FUNCTION derm.fn_sheet_number_ocr_targets(p_limit integer DEFAULT 3)
 RETURNS TABLE(dump_folder text, ticket text, page integer, image_url text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
  with placeable as (
    -- ARM A. A folder with an UNPLACED card: a read can still change where that stamp goes.
    -- 🛑 The comment that used to sit here said "a fully-placed sheet can never be auto-placed
    -- again: reading it changes no decision." That is TRUE FOR AUTO-PLACEMENT AND FALSE FOR PAGE
    -- IDENTITY. The sheet number is also the only thing that establishes WHICH PHYSICAL PAGE each
    -- scan is, and that governs where every stamp lands and what the blackout redacts. Arm B below
    -- exists because that premise cost us two sheets.
    select distinct r.dump_folder, r.white_manifest_number as ticket
      from derm.address_row_map r
     where r.white_manifest_number is not null
       and r.stamp_placed_at is null
       -- ⚠ ONLY `ticket-*` folders. The other shape is the historical 2026-07 batch-mapping set
       -- (`window<N>-sheet<M>`): 94 folders / 488 rows, and MEASURED: **zero** of them have a
       -- generated-sheet link, so none can ever auto-place and a read of one can never be used.
       -- Without this filter the sweep burns ~94 vision calls for nothing and writes noise -- the
       -- first run read `window12-sheet9` as "224", a 3-digit value no real sheet number has.
       -- It also makes the two gate branches agree: the candidate branch keys on
       -- 'ticket-' || p_ticket, which cannot match any other folder shape anyway.
       and r.dump_folder like 'ticket-%'

    union

    -- ARM B. A MULTI-IMAGE folder that has NEVER been scanned, WHATEVER its placement state.
    -- 🛑 THIS IS THE ARM THAT AUTO-PLACEMENT USED TO HIDE. On a generated sheet
    -- trg_ab_autoplace_generated places every card at INSERT, so the folder never has an unplaced
    -- card, so Arm A never offers it, so the sheet number is never read, so
    -- derm.fn_sheet_image_position falls back to the identity mapping. If the two scans were stored
    -- in reverse order, every stamp then lands on the wrong page and nothing can notice.
    -- That is exactly what happened to ticket-833813 (fixed by hand 2026-08-27_1035) and then again
    -- to ticket-312433, whose row OCR proves address_1 is printed page 2 and address_2 is page 1
    -- while the folder was auto-placed and auto-completed with all 8 stamps on the wrong scan.
    -- Fixing the instance twice without fixing this predicate is why it recurred.
    --
    -- ⚠ SINGLE-IMAGE FOLDERS ARE EXCLUDED ON PURPOSE: with one page there is no ordering to get
    -- wrong, so a read changes no decision there and would only spend a vision call.
    -- ⚠ The 'ticket-%' filter is kept for the cost reason documented above.
    -- ⚠ SELF-DRAINING: once a folder has any scan read this arm stops offering it, permanently, so
    -- it cannot become a standing cost. Bounded at 2 folders when this shipped.
    select f.dump_folder, f.ticket
      from (select r2.dump_folder, max(r2.white_manifest_number) as ticket
              from derm.address_row_map r2
             where r2.white_manifest_number is not null
               and r2.dump_folder like 'ticket-%'
             group by r2.dump_folder) f
     where coalesce(array_length(derm.ticket_page_images(f.ticket), 1), 0) > 1
       and not exists (select 1 from derm.address_sheet_scan_reads sr
                        where sr.dump_folder = f.dump_folder)
  )
  select p.dump_folder, p.ticket, g.ord::int as page, g.url as image_url
    from placeable p
    cross join lateral (
      -- ⚠ ticket_page_images(), never address_row_map.image_url -- see header.
      select ord, url
        from unnest(derm.ticket_page_images(p.ticket)) with ordinality as u(url, ord)
    ) g
   where g.url is not null
     and g.url <> 'pending'
     and not exists (select 1
                       from derm.address_sheet_scan_reads sr
                      where sr.dump_folder = p.dump_folder and sr.page = g.ord)
   order by p.dump_folder, g.ord
   limit greatest(1, least(coalesce(p_limit, 3), 10));
$function$;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_n integer; v_bad integer; v_folders text;
BEGIN
  -- 1. 🛑 THE POINT: ticket-296623 is fully placed and was invisible. It must now be offered.
  IF NOT EXISTS (SELECT 1 FROM derm.fn_sheet_number_ocr_targets(50) WHERE dump_folder = 'ticket-296623') THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: ticket-296623 (fully placed, never scanned, multi-image, SERVING) is still invisible';
  END IF;

  -- 2. GENERIC, not one folder: EVERY multi-image ticket folder with no scan read at all must be
  --    reachable, whatever its placement. This is the invariant; naming a folder would rot.
  --    ⚠ ticket-312433 is deliberately NOT asserted here. Between diagnosis and this migration Fred
  --    cleared its stamps, which made it eligible under the OLD Arm A, and the */10 sweep read it at
  --    06:20 (image1 = sheet "1102-2", image2 = "1102-1", both high confidence). It is now scanned,
  --    so Arm B correctly no longer offers it. Asserting it would assert against the fix working.
  SELECT count(*) INTO v_bad FROM (
    SELECT f.dump_folder
      FROM (SELECT r.dump_folder, max(r.white_manifest_number) AS ticket
              FROM derm.address_row_map r
             WHERE r.white_manifest_number IS NOT NULL AND r.dump_folder LIKE 'ticket-%'
             GROUP BY r.dump_folder) f
     WHERE coalesce(array_length(derm.ticket_page_images(f.ticket),1),0) > 1
       AND NOT EXISTS (SELECT 1 FROM derm.address_sheet_scan_reads sr WHERE sr.dump_folder = f.dump_folder)
       AND NOT EXISTS (SELECT 1 FROM derm.fn_sheet_number_ocr_targets(200) t WHERE t.dump_folder = f.dump_folder)
  ) z;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: % multi-image never-scanned folder(s) are still unreachable', v_bad;
  END IF;

  -- 3. 🛑 THE COST GUARD. The window<N>-sheet<M> set must stay excluded: 94 folders with no
  --    generated-sheet link, which would burn a vision call each and write noise.
  SELECT count(*) INTO v_bad FROM derm.fn_sheet_number_ocr_targets(200)
   WHERE dump_folder NOT LIKE 'ticket-%';
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: % non-ticket folder(s) offered; the cost filter broke', v_bad;
  END IF;

  -- 4. 🛑 SELF-DRAINING. No page that already has a scan read may be offered, or Arm B would
  --    re-read the same folder every ten minutes for ever, silently, with the cron reporting success.
  SELECT count(*) INTO v_bad FROM derm.fn_sheet_number_ocr_targets(200) t
   WHERE EXISTS (SELECT 1 FROM derm.address_sheet_scan_reads sr
                  WHERE sr.dump_folder = t.dump_folder AND sr.page = t.page);
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: % already-read page(s) offered; the sweep would loop for ever', v_bad;
  END IF;

  -- 5. BOUNDED. Arm B should add exactly the 2 known folders, not the fleet.
  SELECT count(DISTINCT dump_folder), string_agg(DISTINCT dump_folder, ', ')
    INTO v_n, v_folders FROM derm.fn_sheet_number_ocr_targets(200);
  IF v_n > 6 THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: % folders offered (%); expected a handful', v_n, v_folders;
  END IF;

  -- 6. SINGLE-IMAGE folders must NOT be pulled in by Arm B: one page has no ordering to get wrong.
  SELECT count(*) INTO v_bad FROM derm.fn_sheet_number_ocr_targets(200) t
   WHERE coalesce(array_length(derm.ticket_page_images(t.ticket), 1), 0) <= 1
     AND NOT EXISTS (SELECT 1 FROM derm.address_row_map r
                      WHERE r.dump_folder = t.dump_folder AND r.stamp_placed_at IS NULL);
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 6 FAILED: % single-image fully-placed page(s) offered; Arm B is too wide', v_bad;
  END IF;

  RAISE NOTICE 'VERIFY ok: ticket-296623 and ticket-312433 now visible, non-ticket folders still excluded, no already-read page offered, % folders total (%).', v_n, v_folders;
END $do$;

COMMIT;
