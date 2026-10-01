-- 2026-10-01_1048 Â· Mark completed no longer refuses a sheet because a card sits on a page with no image
--
-- Fred, on ticket 836361 (Stamp Studio showed 2 pages, the DERM Tracker 1): "we only uploaded one image,
-- and we only have 5 stamps clients at the app which match with only one image, so we should work with only
-- that, and only the stamped clients should get the blackout and if there's an image missing or a client
-- missing for the stamp, then they don't get the blackout and that's it."
--
-- WHAT WAS WRONG. 836361 is generated sheet 1124, printed on 2 pages; only page 1's scan was uploaded.
-- Client 288-PER is printed on page 2, and its card (3001) was auto-placed there on 2026-09-22 with no image.
-- derm.fn_blackout_targets already ignores such a card (it bounds effective_page by the ticket's image
-- list) and builds every other page's documents independently, so the 5 page-1 clients could be blacked
-- out. But the COMPLETION gate (fn_sheet_publishable, via v_blackout_blocked_sheets) counted the card on
-- the missing page as "needs_snap_then_extent" and refused the whole sheet, and completion is the publish
-- trigger.
--
-- THE RULE NOW. A stamped card whose page is BEYOND the ticket's image list (derm.fn_card_page_missing)
-- is left out of the completion gate, the blocked-sheets watch list and the per-page hint. It still gets
-- no document, exactly as before. derm.fn_blackout_targets is NOT changed.
--
-- WHAT DOES NOT CHANGE, on purpose:
--  * A page that HAS an image keeps every guard: a stamped card there without snapped bands or without
--    an extent still refuses completion.
--  * A ticket with NO image at all, or a card with no white manifest number (window folders), is never
--    treated as "missing": fn_card_page_missing returns false and the old behaviour holds.
--  * The card is not moved or deleted. If the page-2 scan is uploaded later the card is "present" again,
--    the gate applies to it, and a re-complete publishes 288-PER.
-- Rule 8 (audit): no table changes; one view and three functions.
-- Bodies are the live pg_get_functiondef / pg_get_viewdef output edited by asserted string replacement.

BEGIN;

CREATE TEMP TABLE _before ON COMMIT DROP AS
  SELECT f.dump_folder, derm.fn_sheet_publishable(f.dump_folder) AS blocker
    FROM (SELECT DISTINCT dump_folder FROM derm.address_row_map) f;

CREATE OR REPLACE FUNCTION derm.fn_card_page_missing(p_ticket text, p_page integer)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
  -- TRUE only when we KNOW the page has no image: the ticket has at least one image and the page index
  -- is past the end of its image list. Unknown (no ticket, no images, null page) is FALSE.
  SELECT p_ticket IS NOT NULL AND p_page IS NOT NULL
     AND COALESCE(array_length(derm.ticket_page_images(p_ticket), 1), 0) >= 1
     AND p_page > array_length(derm.ticket_page_images(p_ticket), 1);
$function$;
REVOKE ALL ON FUNCTION derm.fn_card_page_missing(text, integer) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.fn_card_page_missing(text, integer) TO authenticated, service_role, pg_read_all_data;

CREATE OR REPLACE VIEW derm.v_blackout_blocked_sheets AS
 SELECT arm.dump_folder,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL) AS stamped_rows,
    count(DISTINCT COALESCE(arm.stamp_page, arm.page)) FILTER (WHERE arm.stamp_y_pct IS NOT NULL) AS stamped_pages,
    count(DISTINCT arm.matched_manifest_id) FILTER (WHERE arm.matched_manifest_id IS NOT NULL) AS manifests_blocked,
    count(DISTINCT arm.matched_client_id) FILTER (WHERE arm.matched_client_id IS NOT NULL) AS clients_blocked,
    max(arm.stamp_placed_at) AS last_stamp_at,
    now() - max(arm.stamp_placed_at) AS blocked_for,
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM pg_constraint con
                 JOIN pg_class c ON c.oid = con.conrelid
                 JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'derm'::name AND c.relname = 'page_block_extents'::name AND con.contype = 'c'::"char" AND pg_get_constraintdef(con.oid) ~~ (('%'::text || arm.dump_folder) || '%'::text))) THEN 'DELIBERATELY FROZEN by a CHECK constraint on derm.page_block_extents. Do NOT drop it to "unblock" this folder. Read 2026-08-19_2355 PART 5 first: the page grouping is wrong, and opening the gate widens the exposure instead of fixing it.'::text
            WHEN count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND arm.stamp_placed_at IS NOT NULL) = 0 THEN 'NOT a measurement problem. Every stamped row here has a stamp POSITION but no stamp_placed_at, and derm.fn_blackout_targets requires stamp_placed_at. Measuring this folder will not produce a document. The stamp needs to be re-placed through the Studio.'::text
            WHEN count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND (arm.band_y0_pct IS NULL OR arm.band_y1_pct IS NULL)) > 0 THEN 'SNAP THE BANDS FIRST, THEN add the extent, in ONE migration. Some rows here still have DERIVED bands (no band_y0_pct/band_y1_pct override). An extent does not redact anything: it opens the gate onto whatever bands exist, and a derived band is a stamp-midpoint heuristic that is not on the printed rules. Adding the extent alone is what leaked client data on 2026-08-19.'::text
            ELSE 'Bands are already snapped. Add the derm.page_block_extents row for this folder, bounded by the printed roster (first to last form rule, covering empty slots), and verify every band still falls inside it.'::text
        END AS what_to_do,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND arm.stamp_placed_at IS NOT NULL) AS rows_ready,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND arm.stamp_placed_at IS NULL) AS rows_no_stamp_ts,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND (arm.band_y0_pct IS NULL OR arm.band_y1_pct IS NULL)) AS bands_derived,
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM pg_constraint con
                 JOIN pg_class c ON c.oid = con.conrelid
                 JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'derm'::name AND c.relname = 'page_block_extents'::name AND con.contype = 'c'::"char" AND pg_get_constraintdef(con.oid) ~~ (('%'::text || arm.dump_folder) || '%'::text))) THEN 'held_by_constraint'::text
            WHEN count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND arm.stamp_placed_at IS NOT NULL) = 0 THEN 'no_stamp_timestamp'::text
            WHEN count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND (arm.band_y0_pct IS NULL OR arm.band_y1_pct IS NULL)) > 0 THEN 'needs_snap_then_extent'::text
            ELSE 'needs_extent'::text
        END AS blocker
   FROM derm.address_row_map arm
  WHERE arm.stamp_y_pct IS NOT NULL AND NOT (EXISTS ( SELECT 1
           FROM derm.page_block_extents e
          WHERE e.dump_folder = arm.dump_folder AND e.effective_page = COALESCE(arm.stamp_page, arm.page)))
    AND NOT derm.fn_card_page_missing(arm.white_manifest_number, COALESCE(arm.stamp_page, arm.page))
  GROUP BY arm.dump_folder
UNION ALL
 SELECT arm.dump_folder,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL) AS stamped_rows,
    count(DISTINCT COALESCE(arm.stamp_page, arm.page)) FILTER (WHERE arm.stamp_y_pct IS NOT NULL) AS stamped_pages,
    count(DISTINCT arm.matched_manifest_id) FILTER (WHERE arm.matched_manifest_id IS NOT NULL) AS manifests_blocked,
    count(DISTINCT arm.matched_client_id) FILTER (WHERE arm.matched_client_id IS NOT NULL) AS clients_blocked,
    max(arm.stamp_placed_at) AS last_stamp_at,
    now() - max(arm.stamp_placed_at) AS blocked_for,
    'FROZEN, AND ALREADY SERVING. At least one card in this folder has no stamp POINT, which fails derm.fn_blackout_targets whole-folder closed-world gate, so NOTHING in this folder can regenerate - including the documents it is serving right now, which are frozen snapshots. Fix: place the missing stamp(s) in the Stamp Studio. Do NOT just clear the bands - that does not add a stamp and the folder stays frozen. Do NOT delete the cards without checking what the paper says.'::text AS what_to_do,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND arm.stamp_placed_at IS NOT NULL) AS rows_ready,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND arm.stamp_placed_at IS NULL) AS rows_no_stamp_ts,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND (arm.band_y0_pct IS NULL OR arm.band_y1_pct IS NULL)) AS bands_derived,
    'frozen_closed_world'::text AS blocker
   FROM derm.address_row_map arm
  WHERE (EXISTS ( SELECT 1
           FROM derm.address_row_map g
          WHERE g.dump_folder = arm.dump_folder AND g.stamp_y_pct IS NULL)) AND (EXISTS ( SELECT 1
           FROM derm.address_row_map s
             JOIN derm.redacted_manifest_docs d ON d.manifest_id = s.matched_manifest_id AND d.client_id = s.matched_client_id
          WHERE s.dump_folder = arm.dump_folder)) AND NOT (EXISTS ( SELECT 1
           FROM derm.address_row_map a
          WHERE a.dump_folder = arm.dump_folder AND a.stamp_y_pct IS NOT NULL AND NOT (EXISTS ( SELECT 1
                   FROM derm.page_block_extents e
                  WHERE e.dump_folder = a.dump_folder AND e.effective_page = COALESCE(a.stamp_page, a.page))) AND NOT derm.fn_card_page_missing(a.white_manifest_number, COALESCE(a.stamp_page, a.page))))
  GROUP BY arm.dump_folder
UNION ALL
 SELECT arm.dump_folder,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL) AS stamped_rows,
    count(DISTINCT COALESCE(arm.stamp_page, arm.page)) FILTER (WHERE arm.stamp_y_pct IS NOT NULL) AS stamped_pages,
    count(DISTINCT arm.matched_manifest_id) FILTER (WHERE arm.matched_manifest_id IS NOT NULL AND arm.stamp_placed_at IS NULL) AS manifests_blocked,
    count(DISTINCT arm.matched_client_id) FILTER (WHERE arm.matched_client_id IS NOT NULL AND arm.stamp_placed_at IS NULL) AS clients_blocked,
    max(arm.stamp_placed_at) AS last_stamp_at,
    now() - max(arm.stamp_placed_at) AS blocked_for,
    'WITHHELD. One or more cards here have a stamp POSITION but no stamp_placed_at, so derm.fn_blackout_targets skips them and those clients are served NO FOG sheet. This is the state a card is left in when it is deliberately pulled from publication (see 2026-08-27_1015) and also what a half-finished placement looks like. Fix: re-place the stamp through the Studio once the underlying question is settled. Measuring or re-banding this folder will not publish these cards.'::text AS what_to_do,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND arm.stamp_placed_at IS NOT NULL) AS rows_ready,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND arm.stamp_placed_at IS NULL) AS rows_no_stamp_ts,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND (arm.band_y0_pct IS NULL OR arm.band_y1_pct IS NULL)) AS bands_derived,
    'cards_withheld'::text AS blocker
   FROM derm.address_row_map arm
  WHERE (EXISTS ( SELECT 1
           FROM derm.address_row_map w
          WHERE w.dump_folder = arm.dump_folder AND w.stamp_y_pct IS NOT NULL AND w.stamp_placed_at IS NULL AND w.matched_client_id IS NOT NULL AND w.matched_manifest_id IS NOT NULL)) AND NOT (EXISTS ( SELECT 1
           FROM derm.address_row_map a
          WHERE a.dump_folder = arm.dump_folder AND a.stamp_y_pct IS NOT NULL AND NOT (EXISTS ( SELECT 1
                   FROM derm.page_block_extents e
                  WHERE e.dump_folder = a.dump_folder AND e.effective_page = COALESCE(a.stamp_page, a.page))) AND NOT derm.fn_card_page_missing(a.white_manifest_number, COALESCE(a.stamp_page, a.page)))) AND NOT ((EXISTS ( SELECT 1
           FROM derm.address_row_map g
          WHERE g.dump_folder = arm.dump_folder AND g.stamp_y_pct IS NULL)) AND (EXISTS ( SELECT 1
           FROM derm.address_row_map s
             JOIN derm.redacted_manifest_docs d ON d.manifest_id = s.matched_manifest_id AND d.client_id = s.matched_client_id
          WHERE s.dump_folder = arm.dump_folder)))
  GROUP BY arm.dump_folder;

CREATE OR REPLACE FUNCTION derm.fn_sheet_publishable(p_dump_folder text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
  -- NULL means publishable. Any other value is the REASON it is not, and is shown to the operator.
  SELECT COALESCE(
    -- 1. the estate's own detector. It already knows every way a sheet can be unpublishable
    --    (needs_extent, needs_snap_then_extent, cards_withheld, no_stamp_timestamp,
    --    held_by_constraint, frozen_closed_world) and carries the what_to_do text beside it.
    (SELECT b.blocker FROM derm.v_blackout_blocked_sheets b
      WHERE b.dump_folder = p_dump_folder LIMIT 1),
    CASE
      -- 2. nothing placed: there is no document to produce, so "complete" would be meaningless.
      WHEN NOT EXISTS (SELECT 1 FROM derm.address_row_map r
                        WHERE r.dump_folder = p_dump_folder AND r.stamp_y_pct IS NOT NULL)
        THEN 'no_stamps'
      -- 3. a stamped page with no measured extent. This is the exact hard gate in
      --    fn_blackout_targets' geo CTE, restated so completion cannot outrun the measurement.
      WHEN EXISTS (
        SELECT 1
          FROM (SELECT DISTINCT COALESCE(r.stamp_page, r.page) AS pg
                  FROM derm.address_row_map r
                 WHERE r.dump_folder = p_dump_folder AND r.stamp_y_pct IS NOT NULL
                   -- 2026-10-01: a card on a page with no image cannot be blacked out; it does not block.
                   AND NOT derm.fn_card_page_missing(r.white_manifest_number, COALESCE(r.stamp_page, r.page))) sp
         WHERE NOT EXISTS (SELECT 1 FROM derm.page_block_extents e
                            WHERE e.dump_folder = p_dump_folder AND e.effective_page = sp.pg))
        THEN 'needs_extent'
      -- 4. (2026-09-14) a stamped card whose band is still the stamp-midpoint heuristic on a page
      --    that HAS an extent. An extent opens the gate onto whatever bands exist (2026-08-19), and
      --    a stamp cleared and placed again arrives with no band, so this is the one shape the
      --    blocked-sheets view cannot see: it reports derived bands only on pages WITHOUT an extent.
      --    Measured at install: 3 pages estate-wide (ticket-831102 p1+p2, ticket-831325 p1, the dark
      --    scans of 2026-08-20), all completed and serving; they stay completed and are refused only
      --    if re-completed unmeasured, which is the rule.
      WHEN EXISTS (SELECT 1 FROM derm.address_row_map r
                    WHERE r.dump_folder = p_dump_folder AND r.stamp_y_pct IS NOT NULL
                      AND (r.band_y0_pct IS NULL OR r.band_y1_pct IS NULL)
                      AND NOT derm.fn_card_page_missing(r.white_manifest_number, COALESCE(r.stamp_page, r.page)))
        THEN 'needs_snap_then_extent'
      ELSE NULL
    END);
$function$;

CREATE OR REPLACE FUNCTION derm.fn_sheet_publishable_detail(p_dump_folder text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
  WITH code AS (
    SELECT derm.fn_sheet_publishable(p_dump_folder) AS blocker
  ), stamped AS (
    SELECT DISTINCT COALESCE(r.stamp_page, r.page) AS pg
      FROM derm.address_row_map r
     WHERE r.dump_folder = p_dump_folder AND r.stamp_y_pct IS NOT NULL
       AND NOT derm.fn_card_page_missing(r.white_manifest_number, COALESCE(r.stamp_page, r.page))
  ), need_band AS (
    -- a stamped row still on an ESTIMATED band (no manual/snapped override)
    SELECT DISTINCT COALESCE(r.stamp_page, r.page) AS pg
      FROM derm.address_row_map r
     WHERE r.dump_folder = p_dump_folder AND r.stamp_y_pct IS NOT NULL
       AND (r.band_y0_pct IS NULL OR r.band_y1_pct IS NULL)
       AND NOT derm.fn_card_page_missing(r.white_manifest_number, COALESCE(r.stamp_page, r.page))
  ), need_ext AS (
    SELECT s.pg FROM stamped s
     WHERE NOT EXISTS (SELECT 1 FROM derm.page_block_extents e
                        WHERE e.dump_folder = p_dump_folder AND e.effective_page = s.pg)
  ), fin AS (
    -- 2026-09-15: the generated-sheet finisher's latest reason for a page still needing geometry,
    -- so the banner says WHY the sheet was not measured automatically (plain words, from the
    -- ledger derm.generated_measure_attempts).
    SELECT string_agg('Page ' || a.page || ' could not be measured automatically: ' || a.last_reason,
                      ' ' ORDER BY a.page) AS reasons
      FROM derm.generated_measure_attempts a
     WHERE a.dump_folder = p_dump_folder
       AND a.last_outcome IN ('refused', 'error')
       AND a.last_reason IS NOT NULL
       AND a.page IN (SELECT pg FROM need_band UNION SELECT pg FROM need_ext)
  ), agg AS (
    SELECT (SELECT blocker FROM code) AS blocker,
           (SELECT reasons FROM fin) AS finisher_reasons,
           (SELECT coalesce(array_agg(pg ORDER BY pg), '{}') FROM need_band) AS pages_bands,
           (SELECT coalesce(array_agg(pg ORDER BY pg), '{}') FROM need_ext)  AS pages_ext
  )
  SELECT jsonb_build_object(
    'blocker', a.blocker,
    'pages_needing_bands',  to_jsonb(a.pages_bands),
    'pages_needing_extent', to_jsonb(a.pages_ext),
    'finisher_reasons', a.finisher_reasons,
    'message',
      CASE
        WHEN a.blocker IS NULL THEN NULL
        -- Name the page whenever the fault IS per-page. This is the whole point of the function:
        -- 834742 was blocked only by page 3 while page 1 was already correct, and the bare code
        -- sent the operator back to redo the page that was fine.
        WHEN a.blocker IN ('needs_extent', 'needs_snap_then_extent')
             AND (array_length(a.pages_bands, 1) > 0 OR array_length(a.pages_ext, 1) > 0)
          THEN coalesce(a.finisher_reasons || ' ', '') || 'Page ' ||
               array_to_string(
                 (SELECT array_agg(DISTINCT p ORDER BY p)
                    FROM unnest(a.pages_bands || a.pages_ext) AS u(p)), ', ')
               || ': ' || derm.fn_publishable_hint(a.blocker)
        ELSE derm.fn_publishable_hint(a.blocker)
      END)
  FROM agg a;
$function$;

-- VERIFY ------------------------------------------------------------------------------------------
DO $$
DECLARE v_bad text; v_n int;
BEGIN
  IF derm.fn_sheet_publishable('ticket-836361') IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY: 836361 still blocked: %', derm.fn_sheet_publishable('ticket-836361'); END IF;
  IF derm.fn_card_page_missing('836361', 1) OR NOT derm.fn_card_page_missing('836361', 2) THEN
    RAISE EXCEPTION 'VERIFY: helper wrong on 836361'; END IF;
  IF derm.fn_card_page_missing(NULL, 2) OR derm.fn_card_page_missing('no-such-ticket', 2) THEN
    RAISE EXCEPTION 'VERIFY: helper must be false when unknown'; END IF;
  -- only folders holding a card on a missing page may change their answer
  SELECT string_agg(b.dump_folder, ', '), count(*) INTO v_bad, v_n
    FROM _before b
   WHERE b.blocker IS DISTINCT FROM derm.fn_sheet_publishable(b.dump_folder)
     AND NOT EXISTS (SELECT 1 FROM derm.address_row_map r
                      WHERE r.dump_folder = b.dump_folder AND r.stamp_y_pct IS NOT NULL
                        AND derm.fn_card_page_missing(r.white_manifest_number, COALESCE(r.stamp_page, r.page)));
  IF v_n > 0 THEN RAISE EXCEPTION 'VERIFY: unrelated folders changed: %', v_bad; END IF;
  -- authenticated must still read the view (the helper adds an invoker EXECUTE check to its read path)
  SET LOCAL ROLE authenticated;
  PERFORM count(*) FROM derm.v_blackout_blocked_sheets;
  RESET ROLE;
  RAISE NOTICE 'changed: %', (SELECT string_agg(b.dump_folder || ' ' || coalesce(b.blocker,'null') || ' -> '
                                 || coalesce(derm.fn_sheet_publishable(b.dump_folder),'null'), '; ')
                                FROM _before b WHERE b.blocker IS DISTINCT FROM derm.fn_sheet_publishable(b.dump_folder));
END $$;

NOTIFY pgrst, 'reload schema';
COMMIT;
