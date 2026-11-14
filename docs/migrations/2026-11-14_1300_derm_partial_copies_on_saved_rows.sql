-- 2026-11-14_1300_derm_partial_copies_on_saved_rows.sql
--
-- WHAT
-- ----
-- Pick F: on a sheet where a card is left unstamped, the stamped clients get their copies; the unstamped client waits.
-- Until now one card with no stamp point froze EVERY card of its folder (the whole-folder closed-world gate in
-- derm.fn_blackout_targets, reported as 'frozen_closed_world' by arm 2 of derm.v_blackout_blocked_sheets, which
-- derm.fn_sheet_publishable reads), so "Complete anyway" gave a sheet that read Completed and made nothing.
-- Now a folder with an unstamped card is frozen only while it also holds a stamped card that is UNSAFE:
--   (a) its band is not exactly one saved row (band_source is not 'slot', or the band is missing), or
--   (b) its client's shown span on that page ([lowest band top, highest band bottom], which is what the copy maker
--       reveals) holds a saved row (derm.page_slots) that is not one of that client's own rows.
-- The same predicate is written in fn_blackout_targets and in the view, in BOTH places the view states the arm-2
-- condition (arm 2 itself and its negation in arm 3), one anchored edit each. The 'frozen_closed_world' sentence is
-- unchanged (still true when it fires).
--
-- WHY (b), the condition the plan did not have
-- --------------------------------------------
-- The plan (`Building Apps/Ops Portal/docs/specs/2026-11-14-stamping-screen-build-plan.md`, row S2) had (a) only. Its
-- rehearsal found the hole: fn_blackout_targets reveals [min y0, max y1] per manifest and page, and the redactor
-- (redact-manifest-sheet) paints only [blocks_top, y0) and (y1, blocks_bottom]. A client stamped in rows 1 and 3 of
-- #111111 was shown 23.882..47.255, which holds row 2 (32.588..39.569): the row where the unstamped client can be
-- printed. The FOREIGN-BAND exclusion in fn_blackout_targets sees only STAMPED neighbours. With (b) that fixture stays
-- frozen. The main session approved the stricter gate on 2026-11-14 ("Approved: apply S2 with your STRICTER gate").
--
-- WHY at all
-- ----------
-- Fred, 2026-11-12, "go ahead with all the recommendations" on the Manifests and stamping page, whose pick F
-- recommends: "Your words of October 1: the stamped clients get their copies, the others wait." His words of
-- October 1: "only the stamped clients should get the blackout and if there's an image missing or a client missing
-- for the stamp, then they don't get the blackout and that's it." (`Building Apps/Ops Portal/docs/00-fred-picks-
-- 2026-11-12-manifests-and-stamping.md`; the page's text in docs/specs/2026-11-12-manifests-and-stamping-page-data.mjs.)
--
-- REACH
-- -----
-- Today: 20 folders hold an unstamped card and none of them holds a stamped card, so no copy changes on the day.
-- Measured with every copy row and retry row deleted inside a rolled-back transaction (so every eligible manifest page
-- is due): 857 targets over 165 tickets, identical row for row old against new; the view identical row for row (3
-- rows); 0 differing folders without an unstamped card. Time: 954 ms new, 941 ms old (fn_blackout_targets(100000)).
-- Old Stamp host (stamp.unclogme.app): yes, by Fred's decision (pick F "on the old address too"): its "Complete
-- anyway" now gives the stamped clients their copies when every stamped card sits in its own saved row and no client's
-- span holds another row. Readers, measured: redact-manifest-sheet (sweep and completion kick), public.log_blackout_health
-- (the health email), derm.fn_sheet_publishable (and through it set_sheet_completed, the completion trigger
-- fn_completion_requires_geometry, fn_sheet_publishable_detail, fn_stamp_sheet_wait_reason), derm.save_page_geometry
-- (reads the view's blocker in code). clear_stamp_position, set_row_band and _page_geometry_violations name the objects
-- in comments only.
--
-- REHEARSED (rolled back, 2026-11-14 12:40 to 12:55 ET, test ticket #111111):
--   CONTROL, old bodies, fixture 1 (one unstamped card added for the test client): 'frozen_closed_world', 0 targets,
--   Mark completed refused by the trigger, no sweep queued.
--   NEW, fixture 1: 0 blockers, fn_sheet_publishable NULL, Mark completed goes through and queues one sweep kick
--   (net.http_request_queue +1 inside, 0 after the rollback), copy row deleted -> 1 target for manifest 2017 showing
--   23.882..32.588 inside a black area 23.882..63.412; PRIVACY PROOF on the geometry: every saved row of the page that
--   holds no 2017 card (where the unstamped client is printed) lies inside the black area and outside the shown band.
--   NEW, fixture 1b (the stamped card's band_source set to an older value): still frozen. NEW, fixture 2 (2017 stamped in
--   rows 1 and 3, an unstamped card): still frozen, 0 targets. City email for 2017 / 2020 read before and after:
--   already_sent / awaiting_manual_send, 7 sends, unchanged.
-- Locks: CREATE OR REPLACE VIEW holds ACCESS EXCLUSIVE until COMMIT, so only cheap checks run inside; the fixtures run
-- after the commit in the standing check scripts/checks/stamp_partial_copies.mjs (rolled back; CONTROL=1 puts the old
-- bodies back and fails). Rollback: 2026-11-14_rollback_derm_partial_copies_on_saved_rows.sql.

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$
BEGIN
  IF md5(replace(pg_get_functiondef('derm.fn_blackout_targets(integer)'::regprocedure), chr(13), '')) <> '6f6ec2fcdbd08e665530704cc2df1bdd'
    THEN RAISE EXCEPTION 'GUARD: derm.fn_blackout_targets changed since it was read'; END IF;
  IF md5(replace(pg_get_viewdef('derm.v_blackout_blocked_sheets'::regclass), chr(13), '')) <> '1344b7e48ed9c95cfb629682a7c4e453'
    THEN RAISE EXCEPTION 'GUARD: derm.v_blackout_blocked_sheets changed since it was read'; END IF;
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
          AND r6.stamp_placed_at IS NOT NULL
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

CREATE OR REPLACE VIEW derm.v_blackout_blocked_sheets AS
 SELECT arm.dump_folder,
    count(*) FILTER (WHERE (arm.stamp_y_pct IS NOT NULL)) AS stamped_rows,
    count(DISTINCT COALESCE(arm.stamp_page, arm.page)) FILTER (WHERE (arm.stamp_y_pct IS NOT NULL)) AS stamped_pages,
    count(DISTINCT arm.matched_manifest_id) FILTER (WHERE (arm.matched_manifest_id IS NOT NULL)) AS manifests_blocked,
    count(DISTINCT arm.matched_client_id) FILTER (WHERE (arm.matched_client_id IS NOT NULL)) AS clients_blocked,
    max(arm.stamp_placed_at) AS last_stamp_at,
    (now() - max(arm.stamp_placed_at)) AS blocked_for,
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM ((pg_constraint con
                 JOIN pg_class c ON ((c.oid = con.conrelid)))
                 JOIN pg_namespace n ON ((n.oid = c.relnamespace)))
              WHERE ((n.nspname = 'derm'::name) AND (c.relname = 'page_block_extents'::name) AND (con.contype = 'c'::"char") AND (pg_get_constraintdef(con.oid) ~~ (('%'::text || arm.dump_folder) || '%'::text))))) THEN 'DELIBERATELY FROZEN by a CHECK constraint on derm.page_block_extents. Do NOT drop it to "unblock" this folder. Read 2026-08-19_2355 PART 5 first: the page grouping is wrong, and opening the gate widens the exposure instead of fixing it.'::text
            WHEN (count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND (arm.stamp_placed_at IS NOT NULL))) = 0) THEN 'NOT a measurement problem. Every stamped row here has a stamp POSITION but no stamp_placed_at, and derm.fn_blackout_targets requires stamp_placed_at. Measuring this folder will not produce a document. The stamp needs to be re-placed through the Studio.'::text
            WHEN (count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND ((arm.band_y0_pct IS NULL) OR (arm.band_y1_pct IS NULL)))) > 0) THEN 'SNAP THE BANDS FIRST, THEN add the extent, in ONE migration. Some rows here still have DERIVED bands (no band_y0_pct/band_y1_pct override). An extent does not redact anything: it opens the gate onto whatever bands exist, and a derived band is a stamp-midpoint heuristic that is not on the printed rules. Adding the extent alone is what leaked client data on 2026-08-19.'::text
            ELSE 'Bands are already snapped. Add the derm.page_block_extents row for this folder, bounded by the printed roster (first to last form rule, covering empty slots), and verify every band still falls inside it.'::text
        END AS what_to_do,
    count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND (arm.stamp_placed_at IS NOT NULL))) AS rows_ready,
    count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND (arm.stamp_placed_at IS NULL))) AS rows_no_stamp_ts,
    count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND ((arm.band_y0_pct IS NULL) OR (arm.band_y1_pct IS NULL)))) AS bands_derived,
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM ((pg_constraint con
                 JOIN pg_class c ON ((c.oid = con.conrelid)))
                 JOIN pg_namespace n ON ((n.oid = c.relnamespace)))
              WHERE ((n.nspname = 'derm'::name) AND (c.relname = 'page_block_extents'::name) AND (con.contype = 'c'::"char") AND (pg_get_constraintdef(con.oid) ~~ (('%'::text || arm.dump_folder) || '%'::text))))) THEN 'held_by_constraint'::text
            WHEN (count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND (arm.stamp_placed_at IS NOT NULL))) = 0) THEN 'no_stamp_timestamp'::text
            WHEN (count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND ((arm.band_y0_pct IS NULL) OR (arm.band_y1_pct IS NULL)))) > 0) THEN 'needs_snap_then_extent'::text
            ELSE 'needs_extent'::text
        END AS blocker
   FROM derm.address_row_map arm
  WHERE ((arm.stamp_y_pct IS NOT NULL) AND (NOT (EXISTS ( SELECT 1
           FROM derm.page_block_extents e
          WHERE ((e.dump_folder = arm.dump_folder) AND (e.effective_page = COALESCE(arm.stamp_page, arm.page)))))) AND (NOT derm.fn_card_page_missing(arm.white_manifest_number, COALESCE(arm.stamp_page, arm.page))))
  GROUP BY arm.dump_folder
UNION ALL
 SELECT arm.dump_folder,
    count(*) FILTER (WHERE (arm.stamp_y_pct IS NOT NULL)) AS stamped_rows,
    count(DISTINCT COALESCE(arm.stamp_page, arm.page)) FILTER (WHERE (arm.stamp_y_pct IS NOT NULL)) AS stamped_pages,
    count(DISTINCT arm.matched_manifest_id) FILTER (WHERE (arm.matched_manifest_id IS NOT NULL)) AS manifests_blocked,
    count(DISTINCT arm.matched_client_id) FILTER (WHERE (arm.matched_client_id IS NOT NULL)) AS clients_blocked,
    max(arm.stamp_placed_at) AS last_stamp_at,
    (now() - max(arm.stamp_placed_at)) AS blocked_for,
    'FROZEN, AND ALREADY SERVING. At least one card in this folder has no stamp POINT, which fails derm.fn_blackout_targets whole-folder closed-world gate, so NOTHING in this folder can regenerate - including the documents it is serving right now, which are frozen snapshots. Fix: place the missing stamp(s) in the Stamp Studio. Do NOT just clear the bands - that does not add a stamp and the folder stays frozen. Do NOT delete the cards without checking what the paper says.'::text AS what_to_do,
    count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND (arm.stamp_placed_at IS NOT NULL))) AS rows_ready,
    count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND (arm.stamp_placed_at IS NULL))) AS rows_no_stamp_ts,
    count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND ((arm.band_y0_pct IS NULL) OR (arm.band_y1_pct IS NULL)))) AS bands_derived,
    'frozen_closed_world'::text AS blocker
   FROM derm.address_row_map arm
  WHERE ((EXISTS ( SELECT 1
           FROM derm.address_row_map g
          WHERE ((g.dump_folder = arm.dump_folder) AND (g.stamp_y_pct IS NULL)))) AND (EXISTS (SELECT 1 FROM derm.address_row_map h WHERE h.dump_folder = arm.dump_folder AND ((h.stamp_y_pct IS NOT NULL AND (h.band_source IS DISTINCT FROM 'slot' OR h.band_y0_pct IS NULL OR h.band_y1_pct IS NULL)) OR (h.stamp_y_pct IS NOT NULL AND h.matched_manifest_id IS NOT NULL AND EXISTS (
                SELECT 1 FROM derm.page_slots ps
                 WHERE ps.dump_folder = h.dump_folder AND ps.effective_page = COALESCE(h.stamp_page, h.page)
                   AND ps.y0_pct > (SELECT min(o.band_y0_pct) FROM derm.address_row_map o WHERE o.dump_folder = h.dump_folder
                                     AND COALESCE(o.stamp_page, o.page) = COALESCE(h.stamp_page, h.page)
                                     AND o.matched_manifest_id = h.matched_manifest_id AND o.stamp_y_pct IS NOT NULL) - 0.001
                   AND ps.y1_pct < (SELECT max(o.band_y1_pct) FROM derm.address_row_map o WHERE o.dump_folder = h.dump_folder
                                     AND COALESCE(o.stamp_page, o.page) = COALESCE(h.stamp_page, h.page)
                                     AND o.matched_manifest_id = h.matched_manifest_id AND o.stamp_y_pct IS NOT NULL) + 0.001
                   AND NOT EXISTS (SELECT 1 FROM derm.address_row_map o WHERE o.dump_folder = h.dump_folder
                                     AND COALESCE(o.stamp_page, o.page) = COALESCE(h.stamp_page, h.page)
                                     AND o.matched_manifest_id = h.matched_manifest_id AND o.stamp_y_pct IS NOT NULL
                                     AND round(ps.y0_pct, 3) = o.band_y0_pct AND round(ps.y1_pct, 3) = o.band_y1_pct)))))) AND (EXISTS ( SELECT 1
           FROM (derm.address_row_map s
             JOIN derm.redacted_manifest_docs d ON (((d.manifest_id = s.matched_manifest_id) AND (d.client_id = s.matched_client_id))))
          WHERE (s.dump_folder = arm.dump_folder))) AND (NOT (EXISTS ( SELECT 1
           FROM derm.address_row_map a
          WHERE ((a.dump_folder = arm.dump_folder) AND (a.stamp_y_pct IS NOT NULL) AND (NOT (EXISTS ( SELECT 1
                   FROM derm.page_block_extents e
                  WHERE ((e.dump_folder = a.dump_folder) AND (e.effective_page = COALESCE(a.stamp_page, a.page)))))) AND (NOT derm.fn_card_page_missing(a.white_manifest_number, COALESCE(a.stamp_page, a.page))))))))
  GROUP BY arm.dump_folder
UNION ALL
 SELECT arm.dump_folder,
    count(*) FILTER (WHERE (arm.stamp_y_pct IS NOT NULL)) AS stamped_rows,
    count(DISTINCT COALESCE(arm.stamp_page, arm.page)) FILTER (WHERE (arm.stamp_y_pct IS NOT NULL)) AS stamped_pages,
    count(DISTINCT arm.matched_manifest_id) FILTER (WHERE ((arm.matched_manifest_id IS NOT NULL) AND (arm.stamp_placed_at IS NULL))) AS manifests_blocked,
    count(DISTINCT arm.matched_client_id) FILTER (WHERE ((arm.matched_client_id IS NOT NULL) AND (arm.stamp_placed_at IS NULL))) AS clients_blocked,
    max(arm.stamp_placed_at) AS last_stamp_at,
    (now() - max(arm.stamp_placed_at)) AS blocked_for,
    'WITHHELD. One or more cards here have a stamp POSITION but no stamp_placed_at, so derm.fn_blackout_targets skips them and those clients are served NO FOG sheet. This is the state a card is left in when it is deliberately pulled from publication (see 2026-08-27_1015) and also what a half-finished placement looks like. Fix: re-place the stamp through the Studio once the underlying question is settled. Measuring or re-banding this folder will not publish these cards.'::text AS what_to_do,
    count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND (arm.stamp_placed_at IS NOT NULL))) AS rows_ready,
    count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND (arm.stamp_placed_at IS NULL))) AS rows_no_stamp_ts,
    count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND ((arm.band_y0_pct IS NULL) OR (arm.band_y1_pct IS NULL)))) AS bands_derived,
    'cards_withheld'::text AS blocker
   FROM derm.address_row_map arm
  WHERE ((EXISTS ( SELECT 1
           FROM derm.address_row_map w
          WHERE ((w.dump_folder = arm.dump_folder) AND (w.stamp_y_pct IS NOT NULL) AND (w.stamp_placed_at IS NULL) AND (w.matched_client_id IS NOT NULL) AND (w.matched_manifest_id IS NOT NULL)))) AND (NOT (EXISTS ( SELECT 1
           FROM derm.address_row_map a
          WHERE ((a.dump_folder = arm.dump_folder) AND (a.stamp_y_pct IS NOT NULL) AND (NOT (EXISTS ( SELECT 1
                   FROM derm.page_block_extents e
                  WHERE ((e.dump_folder = a.dump_folder) AND (e.effective_page = COALESCE(a.stamp_page, a.page)))))) AND (NOT derm.fn_card_page_missing(a.white_manifest_number, COALESCE(a.stamp_page, a.page))))))) AND (NOT ((EXISTS ( SELECT 1
           FROM derm.address_row_map g
          WHERE ((g.dump_folder = arm.dump_folder) AND (g.stamp_y_pct IS NULL)))) AND (EXISTS (SELECT 1 FROM derm.address_row_map h WHERE h.dump_folder = arm.dump_folder AND ((h.stamp_y_pct IS NOT NULL AND (h.band_source IS DISTINCT FROM 'slot' OR h.band_y0_pct IS NULL OR h.band_y1_pct IS NULL)) OR (h.stamp_y_pct IS NOT NULL AND h.matched_manifest_id IS NOT NULL AND EXISTS (
                SELECT 1 FROM derm.page_slots ps
                 WHERE ps.dump_folder = h.dump_folder AND ps.effective_page = COALESCE(h.stamp_page, h.page)
                   AND ps.y0_pct > (SELECT min(o.band_y0_pct) FROM derm.address_row_map o WHERE o.dump_folder = h.dump_folder
                                     AND COALESCE(o.stamp_page, o.page) = COALESCE(h.stamp_page, h.page)
                                     AND o.matched_manifest_id = h.matched_manifest_id AND o.stamp_y_pct IS NOT NULL) - 0.001
                   AND ps.y1_pct < (SELECT max(o.band_y1_pct) FROM derm.address_row_map o WHERE o.dump_folder = h.dump_folder
                                     AND COALESCE(o.stamp_page, o.page) = COALESCE(h.stamp_page, h.page)
                                     AND o.matched_manifest_id = h.matched_manifest_id AND o.stamp_y_pct IS NOT NULL) + 0.001
                   AND NOT EXISTS (SELECT 1 FROM derm.address_row_map o WHERE o.dump_folder = h.dump_folder
                                     AND COALESCE(o.stamp_page, o.page) = COALESCE(h.stamp_page, h.page)
                                     AND o.matched_manifest_id = h.matched_manifest_id AND o.stamp_y_pct IS NOT NULL
                                     AND round(ps.y0_pct, 3) = o.band_y0_pct AND round(ps.y1_pct, 3) = o.band_y1_pct)))))) AND (EXISTS ( SELECT 1
           FROM (derm.address_row_map s
             JOIN derm.redacted_manifest_docs d ON (((d.manifest_id = s.matched_manifest_id) AND (d.client_id = s.matched_client_id))))
          WHERE (s.dump_folder = arm.dump_folder))))))
  GROUP BY arm.dump_folder;;

DO $v$
BEGIN
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'derm.fn_blackout_targets(integer)'::regprocedure) <> '{postgres=X/postgres,service_role=X/postgres}'
    THEN RAISE EXCEPTION 'VERIFY: fn_blackout_targets grants moved'; END IF;
  IF (SELECT relacl::text FROM pg_class WHERE oid = 'derm.v_blackout_blocked_sheets'::regclass) <> '{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,db_backup_reader=r/postgres}'
    THEN RAISE EXCEPTION 'VERIFY: view grants moved'; END IF;
  IF strpos(pg_get_functiondef('derm.fn_blackout_targets(integer)'::regprocedure), 'FROM derm.page_slots ps') = 0
    THEN RAISE EXCEPTION 'VERIFY: fn_blackout_targets lacks the new gate'; END IF;
  IF (length(pg_get_viewdef('derm.v_blackout_blocked_sheets'::regclass)) - length(replace(pg_get_viewdef('derm.v_blackout_blocked_sheets'::regclass), 'page_slots ps', ''))) / length('page_slots ps') <> 2
    THEN RAISE EXCEPTION 'VERIFY: the view does not carry the new gate in both places'; END IF;
END $v$;

COMMIT;
