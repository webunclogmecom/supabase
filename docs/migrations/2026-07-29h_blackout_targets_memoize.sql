-- 2026-07-29h  derm.fn_blackout_targets: memoize ticket_page_images + index the ticket-key lookup
--
-- Fred, 2026-07-29: "Go option 1 + 2, prove it's identical first."
--
-- THE SYMPTOM. `redact-manifest-sweep` (jobid 10, */5 -> fn_request_blackout_sweep ->
-- redact-manifest-sheet) returned HTTP 500 on EVERY run across the whole ~6h net._http_response
-- retention window: 60 failures, 0 successes, body
--   {"error":"targets rpc failed","status":500,
--    "detail":"{\"code\":\"57014\",...,\"message\":\"canceling statement due to statement timeout\"}"}
-- The edge fn raises that on the FIRST thing it does, a PostgREST call to derm.fn_blackout_targets,
-- so it never reached any image work.
--
-- ⚠ THE ACCURATE DIAGNOSIS IS "MARGINAL", NOT "BROKEN", and the difference matters. Measured through
-- PostgREST with the exact headers the edge fn sends, four consecutive real calls returned HTTP 200 in
-- 7.75s, 7.95s, 7.61s, 7.45s. The effective ceiling is `authenticator`'s statement_timeout = 8s
-- (service_role sets none of its own, so it inherits the login role's). One run had 54 MILLISECONDS of
-- margin. It succeeds when the DB is quiet and dies when it is not, which is why a 6-hour busy window
-- showed 60/60 failures while it passed cleanly minutes later. Anything that only shaves 20% off is
-- not a fix.
--
-- ⚠ NOT A DATA-VOLUME PROBLEM. address_row_map 588 rows, 111 distinct tickets, page_block_extents 137,
-- live derm_manifests 569, redacted_manifest_docs 544, redacted_manifest_errors 0.
--
-- ROOT CAUSE. `derm.ticket_page_images` costs ~1,269 shared buffers / ~9.5 ms PER CALL, and the
-- function invoked it roughly 1,100 times per sweep:
--   * once per candidate card (561) in the `cards` WHERE gate, and
--   * twice per surviving manifest in `geo` (the subscript, and the array_length bound).
-- 561 x 9.5 ms is ~5.3s of the measured 6.9s, and the whole plan burned 1,279,101 buffers to return
-- AT MOST p_limit (=1) row. The per-call cost is its inner predicate
-- `COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) = p_wm`: no index can serve a COALESCE
-- across two columns, so every call sequentially scanned derm_manifests, and it does that twice.
-- (derm._img_etag was investigated and exonerated: it uses `name_prefix_search`, 3 buffers / 1.4 ms.)
--
-- FIX 1 (the big one): compute ticket_page_images ONCE PER DISTINCT TICKET in a MATERIALIZED CTE and
-- join it, cutting ~1,100 calls to 111.
--   ⚠ WHY THIS IS SEMANTICS-PRESERVING BY CONSTRUCTION: the function is STABLE, and the memo key is
--   exactly the argument both call sites already pass. In `cards` it is `r.white_manifest_number`; in
--   `geo` it is `l.tkey`, which IS `r.white_manifest_number` carried through unchanged. So one memo
--   per white_manifest_number serves both.
--   ⚠ AND IT IS A **LEFT** JOIN, deliberately. A card whose white_manifest_number is NULL previously
--   called ticket_page_images(NULL), got '{}', and was dropped by
--   `COALESCE(array_length(...),1),0) > 0`. With a LEFT JOIN its imgs is NULL, the SAME predicate
--   yields 0, and it is dropped identically. An INNER join would also drop it, but by a different
--   mechanism, and silently coupling row survival to join reachability in a PII gate is exactly the
--   kind of change that must not be made casually.
--
-- FIX 2: an expression index for that COALESCE, so each remaining call is cheap too. Measured alone
-- (in a rolled-back transaction) it took buffers 1,279,101 -> 423,666 but time only 6,894 -> 5,465 ms,
-- i.e. a 3x buffer cut for 21% wall-clock. Necessary, nowhere near sufficient, hence both fixes.
--
-- ⚠⚠ NO GATE IS RELAXED. CLAUDE.md and docs/audits/2026-07-10_ocr_band_refinement.md are explicit
-- that the visible region must never be widened, and the v2 leak of 2026-07-10 came from exactly that.
-- Every filter is byte-identical: the fully-banded-sheet check, the order-consistency rank() check,
-- the REQUIRED page_block_extents inner join, the page-identity etag check, the y1 > y0 check, the
-- staleness fingerprint, and the manifest/visit liveness joins. The ONLY change is HOW the image array
-- is obtained, plus one index.
--
-- PROOF OF IDENTITY, run before shipping (Fred's condition). Both variants were built as probe
-- functions inside a ROLLED-BACK transaction with the final "needs work" filter and LIMIT stripped,
-- because the live function returns 0 rows today and comparing two empty sets proves nothing:
--     v1_rows = 543,  v2_rows = 543,  in_v1_not_v2 = 0,  in_v2_not_v1 = 0,  fp_mismatch = 0
-- That is a symmetric-difference-empty comparison over 543 real rows across all ten output columns
-- INCLUDING the md5 fingerprint, which is the value that decides whether a re-redaction fires.
--
-- RULE 8 (ADR 010): no table or column change. An index is neither, and derm_manifests keeps its
-- existing audit trigger untouched. RULE 1: no source-prefixed columns.

-- ---------------------------------------------------------------------------
-- FIX 2 first: the index the memoized calls will still benefit from.
-- Partial on deleted_at IS NULL because ticket_page_images only ever looks at live manifests.
-- 569 live rows, so the build is instantaneous and CONCURRENTLY is unnecessary.
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_derm_manifests_ticket_key
  ON public.derm_manifests ((COALESCE(white_manifest_number, yellow_ticket_number)))
  WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------------------
-- FIX 1: memoized targets. Signature, return type, volatility, security and search_path are all
-- unchanged from the version this replaces.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_blackout_targets(p_limit integer DEFAULT 3)
RETURNS TABLE(manifest_id bigint, client_id bigint, ticket_key text, source_url text,
              effective_page integer, band_y0 numeric, band_y1 numeric,
              blocks_top numeric, blocks_bottom numeric, fingerprint text, old_url text)
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
  ), cards AS (
    SELECT r.id AS card_id, r.dump_folder, r.page AS ocr_page, r.row_index, r.source,
           r.stamp_placed_at, r.matched_manifest_id AS mid, r.matched_client_id AS cid,
           r.white_manifest_number AS tkey, b.band_y0_pct, b.band_y1_pct, b.effective_page,
           ti.imgs
    FROM derm.address_row_map r
    JOIN derm.v_stamp_row_bands b ON b.id = r.id
    LEFT JOIN timg ti ON ti.tkey = r.white_manifest_number      -- LEFT: see header, NULL-ticket parity
    WHERE r.matched_manifest_id IS NOT NULL AND r.matched_client_id IS NOT NULL
      AND r.stamp_placed_at IS NOT NULL
      AND COALESCE(array_length(ti.imgs, 1), 0) > 0             -- identical predicate, memoized input
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
           l.imgs[l.effective_page] AS src,                     -- was (ticket_page_images(l.tkey))[...]
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
$function$;

-- CREATE OR REPLACE preserves grants, but restate the measured pre-change state so this file is
-- self-contained and the anon/authenticated exclusion is explicit rather than inherited. Verified
-- before replacing: anon=false, authenticated=false, yannick_readonly=false, service_role=true.
-- Supabase's ALTER DEFAULT PRIVILEGES is why this is restated at all.
REVOKE ALL     ON FUNCTION derm.fn_blackout_targets(integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION derm.fn_blackout_targets(integer) TO service_role;

-- ---------------------------------------------------------------------------
-- Post-conditions:
--   1. still returns the same thing (0 rows today, i.e. no backlog):
--        SELECT count(*) FROM derm.fn_blackout_targets(1);                      -- 0
--   2. fast enough to have real headroom under the 8s ceiling:
--        EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM derm.fn_blackout_targets(1);
--   3. grants unchanged:
--        anon / authenticated / yannick_readonly = false, service_role = true
--   4. ⚠ the sweep itself is healthy ONLY per net._http_response. cron.job_run_details reports
--      'succeeded' even on a 500 (pg_net is fire-and-forget). See rule 8 in docs/security.md:
--        SELECT id, status_code FROM net._http_response
--         WHERE content LIKE '%targets rpc failed%' AND created > now() - interval '20 minutes';
--        -- must be 0 rows after this ships
-- ---------------------------------------------------------------------------
