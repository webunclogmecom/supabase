-- 2026-07-20c — Stamp Studio: fix Auto-place geometry + #1000+ generated-sheet hard guard
--
-- CONTEXT (Fred): "the 'Auto place all' button is not working correctly... and when a manifest
-- #1000+ shows up will the auto stamping not make an error? we need to fix that and test."
--
-- CONFIRMED DEFECTS (full audit in the 2026-07-20 stamp-studio workflow output; bundle + live-DB
-- evidence):
--   1. GEOMETRY: derm.v_stamp_rows guessed stamps from a hardcoded template — x=6.0 constant,
--      y = 40 + (row_index-0.5)*(52/max_row_index), i.e. rows spread evenly across 40–92% of the
--      page. Real hand-placed stamps (n=534) sit at y 28–62% with ~5.2%/row pitch; the guess lands
--      every stamp too LOW with error GROWING per row (row 6: guess 87.7 vs actual ~58 — deep in
--      the signature area). Zero of 534 stamps kept the auto fingerprint (x=6.000): the office
--      overwrote or abandoned every auto placement. THIS is the "not working correctly".
--   2. Stretch divisor = filled rows, not the pad's printed line count → partially-filled sheets
--      stretch worse; a 1-row sheet got a fixed y=66%.
--   3. NO #1000+ gate at any layer (bundle: zero hits for '1000'/'generated'; views list every
--      manifest number). Zero generated sheets exist today (derm_address_no 0/535) so nothing has
--      broken YET — but the first pdf-service sheet to land would be auto-stamped with the
--      handwritten template. Business rule (Fred 2026-07-20): Studio = handwritten sheets (<#1000
--      pad numbers / 6-digit county numbers); #1000+ = generated PDFs, born-digital, must NEVER
--      need stamping (their customer copy is the born-redacted FOG PDF — they must never enter the
--      stamps→bands→blackout pipeline at all).
--   4. Latent NULL hazard: set_stamp_position's range check let NULL x/y/page through (NULL
--      comparisons aren't TRUE) while still setting stamp_placed_at → "placed" rows with no coords.
--   5. Client looped the RPC per row, aborting on first error (partial state + stale optimistic UI).
--
-- WHAT THIS MIGRATION DOES (DB-first; the CURRENT app immediately gets better guesses because it
-- reads guess_x/y from the view):
--   A. derm.fn_sheet_is_generated(text) — layered predicate: any live manifest on the sheet number
--      with derm_address_no set OR a .pdf address doc, OR a 4-5 digit number >= 1000 (pad numbers
--      are <1000: 68/195/388; county white numbers are 6-digit; the 4-5 digit band belongs to
--      derm_address_seq which STARTS AT 1000 by construction).
--   B. derm.v_stamp_rows — guess cascade replaces the template:
--        (1) band midpoint when a band exists;
--        (2) else measured extent top + capped pitch (<=6%/row) when page_block_extents has the page;
--        (3) else the empirical constants from the 534 real placements: 28 + (i-0.5)*5.2, clamp <=62.
--      guess_x 6.0 → 8.0 (measured mean 7.8). Appends guess_confidence ('low' for link-materialized
--      rows whose row_index is link order, not geometry) and is_generated. Column order preserved,
--      new columns appended (app-compatible).
--   C. derm.v_stamp_sheets — appends is_generated.
--   D. derm.set_stamp_position — hardened: NULL args raise; p_page>=1; generated sheets raise
--      (manual stamping blocked too — born-digital sheets must never need it; Fred can relax later).
--   E. NEW derm.auto_place_page(p_dump_folder, p_page) — server-side auto-place: one transaction,
--      one UPDATE over the page's unplaced rows using the view's guesses; refuses generated sheets,
--      NULL-guess rows are skipped+counted. Same key gate + ACL as set_stamp_position.
--   F. derm.fn_blackout_targets — explicit AND NOT fn_sheet_is_generated(...) (the rule becomes
--      enforced, not incidental-on-missing-extents).
--
-- App-side (Lovable, separate step): call auto_place_page instead of the loop; honest per-page
-- label; is_generated badge + default-hide; optimistic-patch rollback on RPC failure.
-- Smoke tests: A (real handwritten sheet ticket-306915), B (synthetic #1001 refusal + zero writes +
-- NULL-guard regression), C (manual stamp/clear/band regression). Results in the same-cycle docs.

BEGIN;

-- A. the generated-sheet predicate
CREATE OR REPLACE FUNCTION derm.fn_sheet_is_generated(p_sheet_no text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
           SELECT 1 FROM public.derm_manifests m
           WHERE m.deleted_at IS NULL
             AND COALESCE(m.white_manifest_number, m.yellow_ticket_number) = p_sheet_no
             AND (m.derm_address_no IS NOT NULL OR m.derm_address_url ILIKE '%.pdf'))
      OR (p_sheet_no ~ '^[0-9]{4,5}$' AND p_sheet_no::int >= 1000);
$$;

-- B. v_stamp_rows: guess cascade + appended columns (grafted from the live def)
CREATE OR REPLACE VIEW derm.v_stamp_rows AS
 SELECT r.id,
    r.dump_folder,
    r.white_manifest_number,
    r.page,
    r.row_index,
    r.image_url,
    r.facility_name_read,
    r.address_read,
    COALESCE(c.client_code, r.manual_code) AS client_code,
    COALESCE(c.name, r.manual_code) AS client_name,
    ( SELECT min(m.service_date) AS min
           FROM derm_manifests m
          WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = r.white_manifest_number AND m.deleted_at IS NULL) AS service_date,
    r.assignment_status,
    r.confidence,
    r.stamp_x_pct,
    r.stamp_y_pct,
    r.stamp_page,
    8.0 AS guess_x_pct,
    round(CASE
        WHEN r.band_y0_pct IS NOT NULL AND r.band_y1_pct IS NOT NULL
          THEN (r.band_y0_pct + r.band_y1_pct) / 2::numeric
        WHEN ext.top_pct IS NOT NULL
          THEN LEAST(ext.top_pct + (r.row_index::numeric - 0.5)
                     * LEAST((ext.bottom_pct - ext.top_pct) / NULLIF(r.mx, 0)::numeric, 6.0),
                     ext.bottom_pct)
        ELSE LEAST(28::numeric + (r.row_index::numeric - 0.5) * 5.2, 62::numeric)
    END, 3) AS guess_y_pct,
    r.stamp_placed_at IS NOT NULL AS placed,
    r.source = 'stamp-studio'::text AS is_manual,
    r.matched_client_id,
    r.matched_manifest_id,
    r.band_y0_pct,
    r.band_y1_pct,
    r.band_source,
    r.reviewed_at IS NOT NULL AS reviewed,
    r.matched_manifest_id IS NOT NULL AND (EXISTS ( SELECT 1
           FROM manifest_visits mv
          WHERE mv.manifest_id = r.matched_manifest_id)) AS visit_linked,
    ( SELECT count(*) AS count
           FROM manifest_visits mv
          WHERE mv.manifest_id = r.matched_manifest_id) AS linked_visit_count,
    CASE WHEN r.source IN ('derm-link', 'linked-backfill') THEN 'low' ELSE 'ok' END AS guess_confidence,
    derm.fn_sheet_is_generated(r.white_manifest_number) AS is_generated
   FROM ( SELECT a.id, a.dump_folder, a.white_manifest_number, a.page, a.row_index, a.image_url,
            a.facility_name_read, a.address_read, a.matched_client_id, a.assignment_status,
            a.confidence, a.agent_agreement, a.flags, a.source, a.reviewed_by, a.reviewed_at,
            a.created_at, a.updated_at, a.stamp_x_pct, a.stamp_y_pct, a.stamp_page,
            a.stamp_placed_at, a.stamp_placed_by, a.manual_code, a.matched_manifest_id,
            a.band_y0_pct, a.band_y1_pct, a.band_source, a.band_set_at, a.band_set_by,
            max(a.row_index) OVER (PARTITION BY a.dump_folder, a.page) AS mx
           FROM derm.address_row_map a) r
     LEFT JOIN clients c ON c.id = r.matched_client_id
     LEFT JOIN derm.page_block_extents ext
            ON ext.dump_folder = r.dump_folder
           AND ext.effective_page = COALESCE(r.stamp_page, r.page)
  WHERE r.white_manifest_number IS NOT NULL
    AND (r.matched_client_id IS NOT NULL AND c.client_code IS NOT NULL OR r.manual_code IS NOT NULL)
    AND (r.stamp_placed_at IS NOT NULL OR r.manual_code IS NOT NULL
         OR r.matched_manifest_id IS NOT NULL AND (EXISTS ( SELECT 1
              FROM derm_manifests m
             WHERE m.id = r.matched_manifest_id AND m.deleted_at IS NULL)));

-- C. v_stamp_sheets: append is_generated (grafted from the live def)
CREATE OR REPLACE VIEW derm.v_stamp_sheets AS
 WITH tickets AS (
         SELECT DISTINCT COALESCE(derm_manifests.white_manifest_number, derm_manifests.yellow_ticket_number) AS wm
           FROM derm_manifests
          WHERE derm_manifests.deleted_at IS NULL AND COALESCE(derm_manifests.white_manifest_number, derm_manifests.yellow_ticket_number) IS NOT NULL
        UNION
         SELECT DISTINCT address_row_map.white_manifest_number
           FROM derm.address_row_map
          WHERE address_row_map.white_manifest_number IS NOT NULL
        ), folder AS (
         SELECT address_row_map.white_manifest_number AS wm,
            min(address_row_map.dump_folder) AS f
           FROM derm.address_row_map
          WHERE address_row_map.white_manifest_number IS NOT NULL
          GROUP BY address_row_map.white_manifest_number
        ), vis AS (
         SELECT r.white_manifest_number AS wm,
            count(*) AS total,
            count(*) FILTER (WHERE r.matched_client_id IS NOT NULL OR r.manual_code IS NOT NULL) AS matched,
            count(*) FILTER (WHERE r.stamp_placed_at IS NOT NULL) AS placed
           FROM derm.address_row_map r
             LEFT JOIN clients c ON c.id = r.matched_client_id
          WHERE r.white_manifest_number IS NOT NULL AND (r.matched_client_id IS NOT NULL AND c.client_code IS NOT NULL OR r.manual_code IS NOT NULL) AND (r.stamp_placed_at IS NOT NULL OR r.manual_code IS NOT NULL OR r.matched_manifest_id IS NOT NULL AND (EXISTS ( SELECT 1
                   FROM derm_manifests m
                  WHERE m.id = r.matched_manifest_id AND m.deleted_at IS NULL)))
          GROUP BY r.white_manifest_number
        )
 SELECT COALESCE(folder.f, 'ticket-'::text || t.wm) AS dump_folder,
    t.wm AS white_manifest_number,
    ( SELECT min(m.service_date) AS min
           FROM derm_manifests m
          WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = t.wm AND m.deleted_at IS NULL) AS service_date,
    COALESCE(array_length(spi.imgs, 1), 0)::bigint AS page_count,
    spi.imgs AS page_image_urls,
    COALESCE(vis.total, 0::bigint) AS total_rows,
    COALESCE(vis.matched, 0::bigint) AS matched_rows,
    COALESCE(vis.placed, 0::bigint) AS placed_rows,
    COALESCE(s.completed, false) AS completed,
    s.completed_at,
    COALESCE(( SELECT max(m.dump_ticket_date) AS max
           FROM derm_manifests m
          WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = t.wm AND m.deleted_at IS NULL), ( SELECT max(m.service_date) AS max
           FROM derm_manifests m
          WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = t.wm AND m.deleted_at IS NULL)) AS dump_date,
    derm.fn_sheet_is_generated(t.wm) AS is_generated
   FROM tickets t
     LEFT JOIN folder ON folder.wm = t.wm
     LEFT JOIN vis ON vis.wm = t.wm
     LEFT JOIN derm.stamp_sheet_status s ON s.dump_folder = COALESCE(folder.f, 'ticket-'::text || t.wm)
     CROSS JOIN LATERAL ( SELECT derm.ticket_page_images(t.wm) AS imgs) spi;

-- D. hardened set_stamp_position (NULL guards + page>=1 + generated refusal)
CREATE OR REPLACE FUNCTION derm.set_stamp_position(p_row_id bigint, p_page integer, p_x_pct numeric, p_y_pct numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_sheet text;
BEGIN
  PERFORM derm._require_stamp_key();
  IF p_row_id IS NULL OR p_page IS NULL OR p_x_pct IS NULL OR p_y_pct IS NULL THEN
    RAISE EXCEPTION 'stamp arguments must not be null (row=%, page=%, x=%, y=%)', p_row_id, p_page, p_x_pct, p_y_pct;
  END IF;
  IF p_page < 1 THEN RAISE EXCEPTION 'stamp page must be >= 1 (got %)', p_page; END IF;
  IF p_x_pct < 0 OR p_x_pct > 100 OR p_y_pct < 0 OR p_y_pct > 100 THEN
    RAISE EXCEPTION 'stamp percent out of range (x=%, y=%)', p_x_pct, p_y_pct;
  END IF;
  SELECT white_manifest_number INTO v_sheet FROM derm.address_row_map WHERE id = p_row_id;
  IF v_sheet IS NULL AND NOT FOUND THEN RAISE EXCEPTION 'address_row_map id % not found', p_row_id; END IF;
  IF derm.fn_sheet_is_generated(v_sheet) THEN
    RAISE EXCEPTION 'generated sheet %: stamping does not apply', v_sheet;
  END IF;
  UPDATE derm.address_row_map
     SET stamp_x_pct = round(p_x_pct, 3),
         stamp_y_pct = round(p_y_pct, 3),
         stamp_page  = p_page,
         stamp_placed_at = now(),
         stamp_placed_by = coalesce(nullif(current_setting('request.jwt.claim.email', true), ''), 'stamp-studio')
   WHERE id = p_row_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'address_row_map id % not found', p_row_id; END IF;
END $function$;

-- E. server-side auto-place (one transaction, honest counts, generated refusal)
CREATE OR REPLACE FUNCTION derm.auto_place_page(p_dump_folder text, p_page integer)
 RETURNS TABLE(placed integer, skipped integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_sheet text; v_placed integer := 0; v_skipped integer := 0;
BEGIN
  PERFORM derm._require_stamp_key();
  IF p_dump_folder IS NULL OR p_page IS NULL OR p_page < 1 THEN
    RAISE EXCEPTION 'auto-place: bad arguments (folder=%, page=%)', p_dump_folder, p_page;
  END IF;
  SELECT min(white_manifest_number) INTO v_sheet FROM derm.address_row_map WHERE dump_folder = p_dump_folder;
  IF v_sheet IS NULL THEN RAISE EXCEPTION 'auto-place: unknown sheet %', p_dump_folder; END IF;
  IF derm.fn_sheet_is_generated(v_sheet) THEN
    RAISE EXCEPTION 'auto-place refused: generated sheet %', v_sheet;
  END IF;
  SELECT count(*) FILTER (WHERE g.guess_y_pct IS NULL) INTO v_skipped
    FROM derm.v_stamp_rows g
   WHERE g.dump_folder = p_dump_folder AND g.page = p_page AND NOT g.placed;
  UPDATE derm.address_row_map a
     SET stamp_x_pct = round(g.guess_x_pct, 3),
         stamp_y_pct = round(g.guess_y_pct, 3),
         stamp_page  = p_page,
         stamp_placed_at = now(),
         stamp_placed_by = coalesce(nullif(current_setting('request.jwt.claim.email', true), ''), 'stamp-studio')
    FROM derm.v_stamp_rows g
   WHERE g.id = a.id AND g.dump_folder = p_dump_folder AND g.page = p_page
     AND NOT g.placed AND g.guess_y_pct IS NOT NULL;
  GET DIAGNOSTICS v_placed = ROW_COUNT;
  RETURN QUERY SELECT v_placed, v_skipped;
END $function$;

REVOKE ALL ON FUNCTION derm.auto_place_page(text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION derm.auto_place_page(text, integer) TO authenticated, service_role;

COMMIT;

-- F. fn_blackout_targets generated-exclusion is applied as a separate grafted CREATE OR REPLACE
--    (deployed in the same session; see the deploy script — grafted onto the live def with a
--    pattern-count guard, adding: AND NOT derm.fn_sheet_is_generated(r.white_manifest_number)
--    to the stamped-rows CTE).

-- ============================================================================
-- F (DEPLOYED DEFINITION) — derm.fn_blackout_targets with the generated-sheet
-- exclusion grafted onto the live definition (pattern-count guard verified =1).
-- Deployed 2026-07-20 in the same session as the block above.
-- ============================================================================
CREATE OR REPLACE FUNCTION derm.fn_blackout_targets(p_limit integer DEFAULT 3)
 RETURNS TABLE(manifest_id bigint, client_id bigint, ticket_key text, source_url text, effective_page integer, band_y0 numeric, band_y1 numeric, blocks_top numeric, blocks_bottom numeric, fingerprint text, old_url text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
  WITH cards AS (
    SELECT r.id AS card_id, r.dump_folder, r.page AS ocr_page, r.row_index, r.source,
           r.stamp_placed_at, r.matched_manifest_id AS mid, r.matched_client_id AS cid,
           r.white_manifest_number AS tkey, b.band_y0_pct, b.band_y1_pct, b.effective_page
    FROM derm.address_row_map r
    JOIN derm.v_stamp_row_bands b ON b.id = r.id
    WHERE r.matched_manifest_id IS NOT NULL AND r.matched_client_id IS NOT NULL
      AND r.stamp_placed_at IS NOT NULL
      AND NOT derm.fn_sheet_is_generated(r.white_manifest_number)
      AND NOT EXISTS (SELECT 1 FROM derm.address_row_map r2
                      LEFT JOIN derm.v_stamp_row_bands b2 ON b2.id = r2.id
                      WHERE r2.dump_folder = r.dump_folder AND b2.id IS NULL)
      AND NOT EXISTS (
        SELECT 1 FROM (
          SELECT c2.id,
                 rank() OVER (PARTITION BY c2.dump_folder, c2.page ORDER BY c2.stamp_y_pct)  AS yr,
                 rank() OVER (PARTITION BY c2.dump_folder, c2.page ORDER BY c2.row_index)    AS rr
          FROM derm.address_row_map c2
          WHERE c2.dump_folder = r.dump_folder AND c2.source = 'claude-vision-v1'
            AND c2.stamp_y_pct IS NOT NULL AND c2.stamp_page = c2.page AND c2.page = r.page
        ) o WHERE o.id = r.id AND o.yr <> o.rr)
  ), best AS (
    SELECT DISTINCT ON (mid) * FROM cards
    ORDER BY mid, stamp_placed_at DESC NULLS LAST, card_id DESC
  ), live AS (
    SELECT b.* FROM best b
    JOIN public.derm_manifests dm ON dm.id = b.mid AND dm.deleted_at IS NULL AND dm.client_id = b.cid
    WHERE EXISTS (SELECT 1 FROM public.manifest_visits mv
                  JOIN public.visits v ON v.id = mv.visit_id AND v.deleted_at IS NULL
                  WHERE mv.manifest_id = b.mid)
  ), geo AS (
    SELECT l.mid, l.cid, l.tkey, l.dump_folder,
           (derm.ticket_page_images(l.tkey))[l.effective_page] AS src,
           l.effective_page, l.band_y0_pct AS y0, l.band_y1_pct AS y1,
           LEAST(e.top_pct,
                 (SELECT min(b3.band_y0_pct) FROM derm.v_stamp_row_bands b3
                   WHERE b3.dump_folder = l.dump_folder AND b3.effective_page = l.effective_page)) AS btop,
           GREATEST(e.bottom_pct,
                 (SELECT max(b4.band_y1_pct) FROM derm.v_stamp_row_bands b4
                   WHERE b4.dump_folder = l.dump_folder AND b4.effective_page = l.effective_page)) AS bbot
    FROM live l
    JOIN derm.page_block_extents e
      ON e.dump_folder = l.dump_folder AND e.effective_page = l.effective_page   -- HARD GATE: measured pages only
    WHERE l.effective_page >= 1
      AND l.effective_page <= COALESCE(array_length(derm.ticket_page_images(l.tkey), 1), 0)
  ), ok AS (
    SELECT g.* FROM geo g
    WHERE g.src IS NOT NULL AND g.y1 > g.y0
      AND NOT EXISTS (
        SELECT 1 FROM (
          SELECT mode() WITHIN GROUP (ORDER BY r5.image_url) AS ocr_img
          FROM derm.address_row_map r5
          WHERE r5.dump_folder = g.dump_folder AND r5.page = g.effective_page
            AND r5.image_url <> 'pending' AND r5.source = 'claude-vision-v1'
        ) oi
        WHERE oi.ocr_img IS NOT NULL
          AND derm._img_etag(oi.ocr_img) IS DISTINCT FROM derm._img_etag(g.src))
  ), fp AS (
    SELECT o.*, md5(coalesce(derm._img_etag(o.src), 'noetag') || '|' || o.y0 || '|' || o.y1 || '|' ||
                    coalesce(o.btop::text, 'x') || '|' || coalesce(o.bbot::text, 'x')) AS fprint
    FROM ok o
  )
  SELECT f.mid, f.cid, f.tkey, f.src, f.effective_page, f.y0, f.y1, f.btop, f.bbot, f.fprint, t.url
  FROM fp f
  LEFT JOIN derm.redacted_manifest_docs t ON t.manifest_id = f.mid
  LEFT JOIN derm.redacted_manifest_errors e2 ON e2.manifest_id = f.mid
  WHERE (t.manifest_id IS NULL OR t.fingerprint IS DISTINCT FROM f.fprint)
    AND (e2.manifest_id IS NULL OR e2.next_retry_at <= now())
  ORDER BY e2.next_retry_at NULLS FIRST, f.mid
  LIMIT p_limit;
$function$

-- ============================================================================
-- POST-DEPLOY VALIDATION (2026-07-20, Prod):
--   * Guess accuracy vs the 542 real hand-placed stamps (branches 2/3 only, no
--     band circularity): OLD template avg |err| = 24.9 pts -> NEW cascade 3.1 pts.
--   * Predicate: '1001'=generated TRUE; '830088','388','68' (real sheets) FALSE.
--   * v_stamp_sheets: 104 sheets, 0 flagged generated (correct — none exist yet).
--   * ACLs: auto_place_page + set_stamp_position = authenticated+service_role only;
--     fn_blackout_targets ACL preserved (service_role, SECDEF).
--   * fn_blackout_targets(): 0 pending; fn_request_blackout_sweep() ran clean,
--     0 rows in derm.redacted_manifest_errors; 519 redacted docs stable.
-- ============================================================================

-- ============================================================================
-- SMOKE TESTS (2026-07-20, all run against Prod, all mutations reverted):
--   A (real sheet, ticket-306915 p1): cleared rows 659+665 via derm.clear_stamp_position →
--     derm.auto_place_page('ticket-306915',1) returned (placed=2, skipped=0); both rows got
--     x=8.000 (new fingerprint), y == v_stamp_rows.guess_y_pct EXACTLY (30.600 / 61.800,
--     empirical branch, guess_confidence='low' as expected — link-order sheet), stamp_page=1,
--     placed_by='stamp-studio'. Redaction gates held: 0 fn_blackout_targets rows, 0 redacted
--     docs for 306915 (no extents = fail-closed). Both rows restored EXACTLY from snapshot;
--     full-folder re-query byte-identical to baseline.
--   B (#1000+ generated): synthetic manifest white='1001'/derm_address_no=1001 (literal — seq
--     untouched) + synthetic card 'ticket-1001'. v_stamp_sheets/v_stamp_rows flagged
--     is_generated=true; set_stamp_position RAISED 'generated sheet 1001: stamping does not
--     apply'; auto_place_page RAISED 'auto-place refused: generated sheet 1001'; ZERO stamp
--     writes leaked. Synthetics hard-deleted after JSON backup
--     (..\backups\2026-07-20_stamp_smokeB_synthetic_rows.json); manifests/rows/seq counts
--     identical to baseline (553/555/1025), no ghost sheet in the views.
--   C (manual-path regression): set_stamp_position + clear_stamp_position still work on a real
--     sheet; all 5 hardened guards RAISE (NULL row/page/x, page=0, x=150 out of range).
--   App: published to studio.unclogme.app ("Up to date"); live bundle contains auto_place_page,
--     'Auto-place page', is_generated ×3, 'Show generated', guess_confidence, the generated
--     tooltip and the low-confidence banner strings (curl-verified).
-- ============================================================================
