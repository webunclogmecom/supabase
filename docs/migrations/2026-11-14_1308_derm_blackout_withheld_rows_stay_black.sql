-- 2026-11-14_1308_derm_blackout_withheld_rows_stay_black.sql
--
-- WHAT
-- ----
-- derm.fn_blackout_targets, one anchored edit in its FOREIGN-BAND exclusion (the 'ok' CTE): a target is dropped when
-- ANY other client's card WITH A STAMP POINT on that page has a band inside the client's shown span, placed or withheld.
-- Removed: `AND r6.stamp_placed_at IS NOT NULL`. A withheld card (a stamp point and no stamp_placed_at) inside a
-- client's span used to be ignored there, so its printed row showed on that client's copy. Privacy direction only: it can
-- only drop a target, never add one.
--
-- WHY
-- ---
-- Found while applying pick F (2026-11-14_1300): the copy maker (redact-manifest-sheet) blacks out only above and below
-- [min y0, max y1] of a client on a page, so this exclusion is the ONLY thing keeping another client's row inside that
-- span off the copy. Measured, then the main session (Ops Portal Stage D): "Close the gap you measured ... in the
-- privacy-preserving direction only".
--
-- REACH
-- -----
-- Today 0 (no client's span holds a withheld card; 881 groups, 7 with several cards). With every copy due (copy rows
-- deleted inside a rolled-back transaction): 857 targets over 165 tickets, identical row for row old against new.
-- Old Stamp host: none visible. The view derm.v_blackout_blocked_sheets does not restate this exclusion; a dropped target
-- shows in the health email through derm.v_blackout_completed_unpublished once 20 minutes pass (proved in the fixture).
--
-- APPLIED 2026-11-14 13:07 ET. REHEARSED (rolled back, ~13:05 ET, test ticket #111111): 2017 stamped in rows 1 and
-- 3, a withheld card (point, no placement time) in row 2, the sheet completed again. CONTROL, the body before this:
-- 1 target showing 23.882..47.255, the withheld row inside it. NEW: 0 targets, the sheet named by the health email's
-- unpublished view. Rollback (the body before this, md5 b923437983ef04fac085047ff1cf3663) rehearsed in the same
-- transaction. Standing check: scripts/checks/stamp_partial_copies.mjs F3 (CONTROL=1 fails).
-- City email for 2017 / 2020 the same before and after.
-- Rollback: 2026-11-14_rollback_derm_blackout_withheld_rows_stay_black.sql (run it BEFORE the pick F rollback).

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$
BEGIN
  IF md5(replace(pg_get_functiondef('derm.fn_blackout_targets(integer)'::regprocedure), chr(13), '')) <> 'b923437983ef04fac085047ff1cf3663'
    THEN RAISE EXCEPTION 'GUARD: derm.fn_blackout_targets changed since it was read'; END IF;
END $g$;

CREATE OR REPLACE FUNCTION derm.fn_blackout_targets(p_limit integer DEFAULT 3)
 RETURNS TABLE(manifest_id bigint, client_id bigint, ticket_key text, source_url text, effective_page integer, band_y0 numeric, band_y1 numeric, blocks_top numeric, blocks_bottom numeric, fingerprint text, old_url text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
  -- ONE ticket_page_images call per distinct ticket (111) instead of ~1,100. MATERIALIZED is
  -- load-bearing: without it the planner may inline and re-evaluate per reference, which is the
  -- entire bug being fixed here.
  WITH timg AS MATERIALIZED (
    SELECT t.tkey, derm.ticket_page_images(t.tkey) AS imgs
    FROM (SELECT DISTINCT r.white_manifest_number AS tkey
            FROM derm.address_row_map r
           WHERE r.matched_manifest_id IS NOT NULL AND r.matched_client_id IS NOT NULL
             AND r.stamp_placed_at IS NOT NULL
             AND r.white_manifest_number IS NOT NULL) t
  ), bands AS MATERIALIZED (
    -- 🛑 THE 2 SECONDS LIVED HERE. derm.v_stamp_row_bands is a 713-row VIEW costing 3 ms to build
    -- once, but it was referenced FIVE times, three of them inside correlated subqueries that ran
    -- ~640 times each. 3 ms x ~640 = the entire 2,056 ms. Materialising it once is a pure rewrite:
    -- same rows, same columns, evaluated once instead of hundreds of times. MATERIALIZED is
    -- load-bearing for exactly the reason the timg CTE above says it is.
    SELECT * FROM derm.v_stamp_row_bands
  ), cards AS (
    SELECT r.id AS card_id, r.dump_folder, r.page AS ocr_page, r.row_index, r.source,
           r.stamp_placed_at, r.matched_manifest_id AS mid, r.matched_client_id AS cid,
           r.white_manifest_number AS tkey, b.band_y0_pct, b.band_y1_pct, b.effective_page,
           ti.imgs
    FROM derm.address_row_map r
    JOIN bands b ON b.id = r.id
    LEFT JOIN timg ti ON ti.tkey = r.white_manifest_number      -- LEFT: see header, NULL-ticket parity
    WHERE r.matched_manifest_id IS NOT NULL AND r.matched_client_id IS NOT NULL
      AND r.stamp_placed_at IS NOT NULL
      AND COALESCE(array_length(ti.imgs, 1), 0) > 0             -- identical predicate, memoized input
      AND NOT (EXISTS (SELECT 1 FROM derm.address_row_map r2
                       LEFT JOIN bands b2 ON b2.id = r2.id
                       WHERE r2.dump_folder = r.dump_folder AND b2.id IS NULL)
               AND EXISTS (SELECT 1 FROM derm.address_row_map r3
                            WHERE r3.dump_folder = r.dump_folder AND ((r3.stamp_y_pct IS NOT NULL AND (r3.band_source IS DISTINCT FROM 'slot' OR r3.band_y0_pct IS NULL OR r3.band_y1_pct IS NULL)) OR (r3.stamp_y_pct IS NOT NULL AND r3.matched_manifest_id IS NOT NULL AND EXISTS (
                SELECT 1 FROM derm.page_slots ps
                 WHERE ps.dump_folder = r3.dump_folder AND ps.effective_page = COALESCE(r3.stamp_page, r3.page)
                   AND ps.y0_pct > (SELECT min(o.band_y0_pct) FROM derm.address_row_map o WHERE o.dump_folder = r3.dump_folder
                                     AND COALESCE(o.stamp_page, o.page) = COALESCE(r3.stamp_page, r3.page)
                                     AND o.matched_manifest_id = r3.matched_manifest_id AND o.stamp_y_pct IS NOT NULL) - 0.001
                   AND ps.y1_pct < (SELECT max(o.band_y1_pct) FROM derm.address_row_map o WHERE o.dump_folder = r3.dump_folder
                                     AND COALESCE(o.stamp_page, o.page) = COALESCE(r3.stamp_page, r3.page)
                                     AND o.matched_manifest_id = r3.matched_manifest_id AND o.stamp_y_pct IS NOT NULL) + 0.001
                   AND NOT EXISTS (SELECT 1 FROM derm.address_row_map o WHERE o.dump_folder = r3.dump_folder
                                     AND COALESCE(o.stamp_page, o.page) = COALESCE(r3.stamp_page, r3.page)
                                     AND o.matched_manifest_id = r3.matched_manifest_id AND o.stamp_y_pct IS NOT NULL
                                     AND round(ps.y0_pct, 3) = o.band_y0_pct AND round(ps.y1_pct, 3) = o.band_y1_pct))))))
      AND NOT EXISTS (
        SELECT 1 FROM (
          SELECT c2.id,
                 rank() OVER (PARTITION BY c2.dump_folder, c2.page ORDER BY c2.stamp_y_pct)  AS yr,
                 rank() OVER (PARTITION BY c2.dump_folder, c2.page ORDER BY c2.row_index)    AS rr
          FROM derm.address_row_map c2
          WHERE c2.dump_folder = r.dump_folder AND c2.source = 'claude-vision-v1'
            AND c2.stamp_y_pct IS NOT NULL AND c2.stamp_page = c2.page AND c2.page = r.page
        ) o WHERE o.id = r.id AND o.yr <> o.rr)
  ), grp AS (
    -- 🛑 GROUP FIRST, ELECT SECOND. The old DISTINCT ON (mid) was doing TWO jobs and only one was
    -- wanted. Job 1, legitimate: a manifest can carry placed cards in more than one
    -- (dump_folder, effective_page) group, and without an election each would emit a target that
    -- upserts the same PK and fights every sweep. Job 2, the DEFECT: it also discarded a manifest's
    -- other PERMIT cards INSIDE the winning group, so a client holding several GDO permits on one
    -- sheet was served only ONE of its own printed rows. Grouping first keeps job 1 and drops job 2.
    SELECT c.mid, c.cid, c.tkey, c.dump_folder, c.effective_page,
           max(c.imgs)                                   AS imgs,
           count(*)                                      AS n_bands,
           min(c.band_y0_pct)                            AS band_y0_pct,
           max(c.band_y1_pct)                            AS band_y1_pct,
           string_agg(c.band_y0_pct::text || '|' || c.band_y1_pct::text, '|'
                      ORDER BY c.band_y0_pct)            AS band_str,
           max(c.stamp_placed_at)                        AS stamp_placed_at,
           max(c.card_id)                                AS card_id
    FROM cards c
    GROUP BY c.mid, c.cid, c.tkey, c.dump_folder, c.effective_page
  ), elect AS (
    -- 🛑 ELECT A FOLDER, NOT A PAGE. The DISTINCT ON here still exists for its ONE legitimate job:
    -- 5 manifests carry placed cards in more than one dump_folder (1246/1247/1248/1249 are the same
    -- paper carded in both `derm/1246` and `ticket-828604`), and without an election each folder
    -- would emit a target that upserts the same row and fights every sweep. It must NOT also discard
    -- the manifest's other PAGES, which is what kept 043-MIL and 022-GRO seeing one page of their own
    -- record. So elect the folder here, then keep every page of it below.
    -- ⚠ This is why the key cannot simply be (manifest_id, effective_page): those 4 manifests collide
    -- on it, having two folders at the SAME page.
    SELECT DISTINCT ON (mid) mid, dump_folder FROM grp
    ORDER BY mid, stamp_placed_at DESC NULLS LAST, card_id DESC
  ), best AS (
    SELECT g.* FROM grp g
    JOIN elect e ON e.mid = g.mid AND e.dump_folder = g.dump_folder
  ), live AS (
    SELECT b.* FROM best b
    JOIN public.derm_manifests dm ON dm.id = b.mid AND dm.deleted_at IS NULL AND dm.client_id = b.cid
    WHERE EXISTS (SELECT 1 FROM public.manifest_visits mv
                  JOIN public.visits v ON v.id = mv.visit_id AND v.deleted_at IS NULL
                  WHERE mv.manifest_id = b.mid)
      -- 🛑 COMPLETION IS THE PUBLISH TRIGGER (2026-09-03). A sheet only publishes while a person
      -- has signed it off; a DIRTY sheet keeps serving whatever it already has and regenerates
      -- nothing until it is re-completed. Fred, 2026-08-27: "when uncompleting and completing it
      -- again it needs to be blackedout again". Measured no-op at install: 136 folders, all
      -- completed, 0 targets, 0 serving folders without a status row.
      AND EXISTS (SELECT 1 FROM derm.stamp_sheet_status s
                   WHERE s.dump_folder = b.dump_folder AND s.completed)
  ), geo AS (
    SELECT l.mid, l.cid, l.tkey, l.dump_folder,
           l.imgs[l.effective_page] AS src,                     -- was (ticket_page_images(l.tkey))[...]
           l.effective_page, l.band_y0_pct AS y0, l.band_y1_pct AS y1, l.band_str, l.n_bands,
           LEAST(e.top_pct,
                 (SELECT min(b3.band_y0_pct) FROM bands b3
                   WHERE b3.dump_folder = l.dump_folder AND b3.effective_page = l.effective_page)) AS btop,
           GREATEST(e.bottom_pct,
                 (SELECT max(b4.band_y1_pct) FROM bands b4
                   WHERE b4.dump_folder = l.dump_folder AND b4.effective_page = l.effective_page)) AS bbot
    FROM live l
    JOIN derm.page_block_extents e
      ON e.dump_folder = l.dump_folder AND e.effective_page = l.effective_page   -- HARD GATE: measured pages only
    WHERE l.effective_page >= 1
      AND l.effective_page <= COALESCE(array_length(l.imgs, 1), 0)               -- same bound, memoized
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
      -- 🛑 FOREIGN-BAND EXCLUSION. y0..y1 is now the UNION of a client's rows, and the redactor
      -- paints exactly two boxes: [btop..y0] and [y1..bbot]. So everything BETWEEN y0 and y1 is
      -- revealed. That is correct only while the interval contains nothing but this client's own
      -- rows. Measured 2026-08-27: 0 groups violate it and 0 groups have an internal gap, so this
      -- refuses nothing today -- it is here so a future non-contiguous group FAILS CLOSED (no
      -- document) instead of publishing a neighbour's printed row.
      AND NOT EXISTS (
        SELECT 1 FROM derm.address_row_map r6
        JOIN bands b6 ON b6.id = r6.id
        WHERE r6.dump_folder = g.dump_folder
          AND COALESCE(r6.stamp_page, r6.page) = g.effective_page
          -- 2026-11-14: EVERY card with a stamp point counts, placed or withheld (a withheld card has a point and no
          -- stamp_placed_at); otherwise its printed row inside this client's span would show on this client's copy.
          AND (r6.matched_manifest_id IS DISTINCT FROM g.mid
            OR r6.matched_client_id   IS DISTINCT FROM g.cid)
          AND b6.band_y0_pct < g.y1 AND g.y0 < b6.band_y1_pct)
  ), fp AS (
    SELECT o.*, md5(coalesce(derm._img_etag(o.src), 'noetag') || '|' || o.band_str || '|' ||
                    coalesce(o.btop::text, 'x') || '|' || coalesce(o.bbot::text, 'x')) AS fprint
    FROM ok o
  )
  SELECT f.mid, f.cid, f.tkey, f.src, f.effective_page, f.y0, f.y1, f.btop, f.bbot, f.fprint, t.url
  FROM fp f
  -- 🛑 PER PAGE. Without the page this compares a page-2 target against the page-1 ledger row,
  -- so the fingerprints never match, every page-2 document is permanently stale, and the sweep
  -- republishes it every five minutes for ever.
  LEFT JOIN derm.redacted_manifest_docs t
         ON t.manifest_id = f.mid AND t.effective_page = f.effective_page
  LEFT JOIN derm.redacted_manifest_errors e2 ON e2.manifest_id = f.mid
  WHERE (t.manifest_id IS NULL OR t.fingerprint IS DISTINCT FROM f.fprint)
    AND (e2.manifest_id IS NULL OR e2.next_retry_at <= now())
  ORDER BY e2.next_retry_at NULLS FIRST, f.mid
  LIMIT p_limit;
$function$;

DO $v$
BEGIN
  IF strpos(pg_get_functiondef('derm.fn_blackout_targets(integer)'::regprocedure), 'r6.stamp_placed_at') > 0
    THEN RAISE EXCEPTION 'VERIFY: the exclusion still filters on stamp_placed_at'; END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'derm.fn_blackout_targets(integer)'::regprocedure) <> '{postgres=X/postgres,service_role=X/postgres}'
    THEN RAISE EXCEPTION 'VERIFY: fn_blackout_targets grants moved'; END IF;
END $v$;

COMMIT;
