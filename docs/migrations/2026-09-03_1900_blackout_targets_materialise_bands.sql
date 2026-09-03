-- 2026-09-03_1900_blackout_targets_materialise_bands.sql
--
-- derm.fn_blackout_targets took 2,056 ms EVERY run to return zero rows. This makes it return the
-- same rows in a fraction of the time. It is a PURE REWRITE: no predicate changed, no branch added.
--
-- ============================================================================
-- WHERE THE 2 SECONDS ACTUALLY WENT
-- ============================================================================
-- Not where it looked. Measured, in order of suspicion:
--   ticket_page_images(), 135 calls, MATERIALIZED ......  209 ms  (10%, not the problem)
--   the windowed NOT EXISTS in `cards` .................  0.015 ms x 702 loops (~10 ms, not it)
--   derm.v_stamp_row_bands ............................. THE REST
--
-- `derm.v_stamp_row_bands` is a VIEW of **713 rows** that costs **3 ms** to build once. It was
-- referenced FIVE times, three of them inside correlated subqueries evaluated ~640 times each.
-- 3 ms x ~640 = the whole 2,056 ms. The plan shows it plainly:
--   Nested Loop Anti Join  1,192 ms   (foreign-band exclusion, per row)
--   Hash Join                878 ms   (1.3 ms x 666 loops)
--   Merge Left Join          821 ms   (1.3 ms x 643 loops)
--   GroupAggregate           534 ms   (0.8 ms x 643 loops)
--   two Aggregates           877 ms   (the min/max band subqueries in `geo`)
-- Every one of those is the same 713 rows being re-derived.
--
-- THE FIX: build it once into a MATERIALIZED CTE and point the five sites at it.
--
-- 🛑 WHAT THIS DELIBERATELY DOES NOT DO: add a short-circuit. The tempting optimisation is "return
-- early when nothing has changed", and it is the wrong thing to do HERE. This function decides
-- which client documents get REDACTED. A short-circuit that is wrong in the false direction means a
-- sheet that should have been blacked out silently is not, and nothing reports it. Failing open on
-- client PII is not worth two seconds. Every predicate is preserved exactly.
--
-- ⚠ THE HONEST SIZE OF THE WIN, because the audit that found this OVERSTATED it. This query is
-- ~32-37% of all DATABASE EXECUTION TIME, but total query load is only about **2.2% of one core**
-- (credit: the Supabase 2 session, who caught it). So this returns roughly **0.7% of one core**, not
-- "a third of the database's capacity" as `docs/audits/2026-09-03_slow_fetch_audit.md` originally
-- claimed - that sentence is being corrected in the same change. This is worth doing because it is
-- free waste, NOT because it will fix the reported slowness.
--
-- ============================================================================
-- HOW EQUIVALENCE WAS PROVEN, AND WHY NOT THE OBVIOUS WAY
-- ============================================================================
-- Both the old and the new function correctly return **0 rows** today, because no blackout work is
-- pending. Comparing their outputs would therefore compare 0 against 0 and prove nothing.
--
-- So the FULL candidate pipeline was compared instead, with the final ledger filter
-- (`t.fingerprint IS DISTINCT FROM f.fprint`) and the LIMIT removed, which exercises every CTE on
-- real data:
--     old_rows 666 | new_rows 666 | only_in_old 0 | only_in_new 0
-- Reproduce by taking both bodies, cutting each at `WHERE (t.manifest_id IS NULL`, and running
-- EXCEPT ALL in both directions.
--
-- Rollback: the previous definition is in git immediately before this commit.

begin;

CREATE OR REPLACE FUNCTION derm.fn_blackout_targets(p_limit integer DEFAULT 3)
 RETURNS TABLE(manifest_id bigint, client_id bigint, ticket_key text, source_url text,
               effective_page integer, band_y0 numeric, band_y1 numeric, blocks_top numeric,
               blocks_bottom numeric, fingerprint text, old_url text)
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
      AND NOT EXISTS (SELECT 1 FROM derm.address_row_map r2
                      LEFT JOIN bands b2 ON b2.id = r2.id
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

do $verify$
declare
  v_rows  integer;
  v_ms    numeric;
  v_t0    timestamptz;
  v_secdef boolean;
  v_vol    char;
begin
  -- shape preserved: still SECURITY DEFINER and still STABLE. A rewrite that quietly dropped
  -- SECURITY DEFINER would 403 for every caller; one that became VOLATILE would stop being
  -- inlinable and could change plans elsewhere.
  select p.prosecdef, p.provolatile into v_secdef, v_vol
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'derm' and p.proname = 'fn_blackout_targets';
  if not coalesce(v_secdef,false) then raise exception 'VERIFY FAILED: no longer SECURITY DEFINER'; end if;
  if v_vol <> 's' then raise exception 'VERIFY FAILED: volatility changed to %, expected STABLE', v_vol; end if;

  -- behaviour preserved: still returns the same (empty) target set right now
  select count(*) into v_rows from derm.fn_blackout_targets(50);
  if v_rows <> 0 then
    raise exception 'VERIFY FAILED: expected 0 targets (none pending before this change), got %. '
                    'A rewrite must not INVENT work.', v_rows;
  end if;

  -- ...and it is actually faster.
  -- ⚠ THE BAR IS 1000 ms AND THAT NUMBER WAS MEASURED, NOT GUESSED. My first attempt asserted
  -- 500 ms, failed at 514 ms and rolled the whole migration back. The rewrite was working fine; the
  -- BAR was wrong, because I had not measured the floor before picking it. Profiling the rewritten
  -- body gives 558 ms, of which **209 ms is the timg CTE alone** (135 ticket_page_images() calls,
  -- which this change does not touch). So ~550 ms is the honest floor for THIS rewrite and no
  -- threshold below it can ever pass.
  -- 1000 ms sits between the floor (~550) and the old cost (2,056), so it still catches the failure
  -- it exists to catch - "the materialised CTE is not being used" - without flapping under load.
  -- Loosening a failing assertion until it goes green is usually the wrong instinct; it is right
  -- only when the assertion, not the code, is what was wrong. That is the case here and this comment
  -- exists so the next reader can judge that for themselves.
  v_t0 := clock_timestamp();
  perform count(*) from derm.fn_blackout_targets(50);
  v_ms := extract(epoch from (clock_timestamp() - v_t0)) * 1000;
  if v_ms > 1000 then
    raise exception 'VERIFY FAILED: still % ms, expected ~550 and well under 1000 (was 2,056). '
                    'The materialised CTE is not being used.', round(v_ms);
  end if;

  raise notice 'VERIFY OK: SECURITY DEFINER + STABLE preserved, 0 targets as before, now % ms (was 2,056; floor ~550 is the timg CTE)', round(v_ms);
end
$verify$;

commit;
