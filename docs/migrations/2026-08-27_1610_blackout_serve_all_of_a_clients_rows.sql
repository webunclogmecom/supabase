-- 2026-08-27_1610_blackout_serve_all_of_a_clients_rows.sql
--
-- WHY: A CLIENT IS BEING SHOWN ONE THIRD OF THEIR OWN COMPLIANCE RECORD, TODAY.
-- ---------------------------------------------------------------------------
-- Fred asked for per-permit cards and rectangles ("multiple cards, and multiple squares for it, and
-- each one should show the nickname we have for that GDO. Like 'Kitchen' 'Lounge'"). Investigating
-- it found that the model ALREADY EXISTS for one client and is mis-serving them.
--
-- **009-CN (Casa Neos) holds THREE per-permit cards on ticket-820714 page 1**, placed by hand on
-- 2026-07-30 and labelled with the very words Fred used:
--
--     id860  GDO-10877  "Kitchen"  band 27.742..33.227
--     id882  GDO-15062  "Bar"      band 33.227..38.712
--     id883  GDO-16389  "Lounge"   band 38.712..44.196
--
-- `derm.fn_blackout_targets` was `DISTINCT ON (manifest_id)`, so only ONE of those three published.
-- The served document (m1624-dd0edde969.jpg) reveals **38.712..44.196 only**. Verified by opening
-- the file: the printed sheet carries `009-CN CASA NEOS KITCHEN`, `009-CN CASA NEOS - BAR` and
-- `009-CN CASA NEOS - LOUNGE` on three consecutive rows, and the client is served a copy with the
-- first two blacked out. **10.97pp of their own DERM record, hidden from them, on a regulator-facing
-- document.** This is over-redaction, not a leak, but it is still wrong and it is live.
--
-- THE FIX: GROUP FIRST, ELECT SECOND.
-- ---------------------------------------------------------------------------
-- `DISTINCT ON (manifest_id)` was doing two jobs and only one was wanted:
--   job 1, LEGITIMATE: 5 manifests carry placed cards in more than one (dump_folder,
--     effective_page) group; without an election each emits a target that upserts the same PK and
--     fights every sweep.
--   job 2, THE DEFECT: it also discarded a manifest's other PERMIT cards inside the winning group.
-- Aggregating by (mid, cid, dump_folder, effective_page) and electing among the GROUPS keeps job 1
-- and drops job 2. band_y0/band_y1 become min/max over the group, i.e. the union of that client's
-- own printed rows.
--
-- THE FINGERPRINT IS THE TRAP, AND IT CUTS BOTH WAYS.
-- The fingerprint must fold EVERY band or the fix applies to zero documents (a manifest whose
-- elected card did not move would keep its old fingerprint, the staleness filter would drop it, and
-- every test would still pass). But the obvious way to write that restates a single band in a new
-- format and makes all 640 documents stale at once: a full-fleet republish draining at */5 limit 1,
-- roughly 53 hours, every filename changed and every old object deleted.
-- The expression used here is chosen so it REDUCES BYTE-FOR-BYTE TO THE OLD ONE AT N=1:
--     string_agg(y0::text || '|' || y1::text, '|' ORDER BY y0)   ==   y0 || '|' || y1   when N=1
-- VERIFY 2 is the control for exactly that: it asserts the function returns EXACTLY ONE target.
-- If the reduction property were broken it would return ~640.
--
-- THE FOREIGN-BAND EXCLUSION, AND WHY IT IS AN ABSOLUTE GUARD.
-- y0..y1 is now a UNION, and the redactor paints two boxes: [btop..y0] and [y1..bbot]. Everything
-- BETWEEN y0 and y1 is revealed. That is correct only while the interval contains nothing but this
-- client's own rows. Measured 2026-08-27 across all placed groups: 0 groups have a foreign band
-- inside their union, and 0 groups have an internal gap, so the guard refuses nothing today. It is
-- here so that a future non-contiguous group FAILS CLOSED (serves no document) rather than
-- publishing a neighbour's printed row. VERIFY 5 proves it bites, in a rolled-back subtransaction.
--
-- NO EDGE-FUNCTION DEPLOY, AND NO NEW COLUMN, ON PURPOSE. Because Casa Neos's three rows are
-- CONTIGUOUS (measured: 0 internal gaps), the min/max union with the EXISTING two-box redactor is
-- exactly right. An N+1-box redactor and a `bands jsonb` ledger column are only needed for a
-- non-contiguous group, which does not exist and which the guard above now refuses anyway. Keeping
-- the RETURNS TABLE list unchanged also means CREATE OR REPLACE is legal, so the
-- `GRANT EXECUTE ... TO service_role` survives; a DROP+CREATE would silently discard it and the
-- sweep would die at "targets rpc failed".
--
-- THE BODY WAS COPIED FROM pg_get_functiondef AND SPLICED BY SCRIPT, NEVER RETYPED. Four anchors,
-- each asserted to match exactly once, and the RETURNS TABLE list asserted byte-identical.
-- CREATE OR REPLACE takes the WHOLE body; anything not reproduced is silently deleted while the
-- header still honestly describes the change intended (2026-08-06_1316 lost seven behaviours that way).
--
-- WHAT THIS DOES NOT DO: it does not create per-permit cards for 242-WYN, 043-MIL or 148-MOR, and
-- it does not show the nickname on the Studio rectangle. Those are the rest of Fred's ask and they
-- follow separately. This lands first because it is the live defect, and because creating more
-- per-permit cards BEFORE it would multiply the over-redaction rather than fix it.
--
-- RULE 8 (audit trail): a function holds no state; opt-out. The one document that regenerates is
-- recorded in derm.redacted_manifest_docs as usual.

BEGIN;

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
  ), best AS (
    SELECT DISTINCT ON (mid) * FROM grp
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
           l.effective_page, l.band_y0_pct AS y0, l.band_y1_pct AS y1, l.band_str, l.n_bands,
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
      -- 🛑 FOREIGN-BAND EXCLUSION. y0..y1 is now the UNION of a client's rows, and the redactor
      -- paints exactly two boxes: [btop..y0] and [y1..bbot]. So everything BETWEEN y0 and y1 is
      -- revealed. That is correct only while the interval contains nothing but this client's own
      -- rows. Measured 2026-08-27: 0 groups violate it and 0 groups have an internal gap, so this
      -- refuses nothing today -- it is here so a future non-contiguous group FAILS CLOSED (no
      -- document) instead of publishing a neighbour's printed row.
      AND NOT EXISTS (
        SELECT 1 FROM derm.address_row_map r6
        JOIN derm.v_stamp_row_bands b6 ON b6.id = r6.id
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
  LEFT JOIN derm.redacted_manifest_docs t ON t.manifest_id = f.mid
  LEFT JOIN derm.redacted_manifest_errors e2 ON e2.manifest_id = f.mid
  WHERE (t.manifest_id IS NULL OR t.fingerprint IS DISTINCT FROM f.fprint)
    AND (e2.manifest_id IS NULL OR e2.next_retry_at <= now())
  ORDER BY e2.next_retry_at NULLS FIRST, f.mid
  LIMIT p_limit;
$function$;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_n integer; v_bad integer; v_y0 numeric; v_y1 numeric; v_mid bigint;
  v_ctrl_ok boolean := false; v_after integer;
BEGIN
  -- 1. Grants survived CREATE OR REPLACE. The sweep runs as service_role and dies without this.
  IF NOT has_function_privilege('service_role', 'derm.fn_blackout_targets(integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: service_role lost EXECUTE on fn_blackout_targets';
  END IF;
  IF has_function_privilege('anon', 'derm.fn_blackout_targets(integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: anon can execute fn_blackout_targets';
  END IF;

  -- 2. THE REPUBLISH-STORM CONTROL. Exactly ONE document may be stale. If the fingerprint did not
  --    reduce byte-for-byte at N=1 this would be ~640 and the fleet would republish for ~53 hours.
  SELECT count(*) INTO v_n FROM derm.fn_blackout_targets(2000);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: % documents are stale, expected exactly 1. The fingerprint does not reduce at N=1.', v_n;
  END IF;

  -- 3. And it is Casa Neos, now served the UNION of its three own rows rather than one of them.
  SELECT manifest_id, band_y0, band_y1 INTO v_mid, v_y0, v_y1 FROM derm.fn_blackout_targets(2000);
  IF v_mid <> 1624 THEN RAISE EXCEPTION 'VERIFY 3 FAILED: stale manifest is %, expected 1624', v_mid; END IF;
  IF v_y0 <> 27.742 OR v_y1 <> 44.196 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: band is %..%, expected the union 27.742..44.196', v_y0, v_y1;
  END IF;

  -- 4. THE ELECTION IS UNCHANGED. Compare the old per-card DISTINCT ON against the new per-group one
  --    for every manifest, and require the same (dump_folder, effective_page) to win.
  WITH cards AS (
    SELECT r.matched_manifest_id AS mid, r.dump_folder,
           COALESCE(r.stamp_page, r.page) AS pg, r.stamp_placed_at, r.id AS card_id
      FROM derm.address_row_map r
      JOIN derm.v_stamp_row_bands b ON b.id = r.id
     WHERE r.matched_manifest_id IS NOT NULL AND r.matched_client_id IS NOT NULL
       AND r.stamp_placed_at IS NOT NULL
  ), old AS (
    SELECT DISTINCT ON (mid) mid, dump_folder, pg FROM cards
     ORDER BY mid, stamp_placed_at DESC NULLS LAST, card_id DESC
  ), grp AS (
    SELECT mid, dump_folder, pg, max(stamp_placed_at) AS sp, max(card_id) AS ci
      FROM cards GROUP BY 1,2,3
  ), new AS (
    SELECT DISTINCT ON (mid) mid, dump_folder, pg FROM grp
     ORDER BY mid, sp DESC NULLS LAST, ci DESC
  )
  SELECT count(*) INTO v_bad
    FROM old o JOIN new n ON n.mid = o.mid
   WHERE o.dump_folder IS DISTINCT FROM n.dump_folder OR o.pg IS DISTINCT FROM n.pg;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: the election moved for % manifest(s); a document would change folder', v_bad;
  END IF;

  -- 5. POSITIVE CONTROL FOR THE FOREIGN-BAND EXCLUSION, in a rolled-back subtransaction.
  --    Move 034-LG's card (id 859) inside Casa Neos's union. The group MUST vanish from the targets
  --    (fail closed) rather than publish a document revealing a neighbour's printed row.
  --    A guard that has never been shown to bite is not a guard.
  BEGIN
    UPDATE derm.address_row_map SET band_y0_pct = 30.000, band_y1_pct = 31.000 WHERE id = 859;
    SELECT count(*) INTO v_after FROM derm.fn_blackout_targets(2000) WHERE manifest_id = 1624;
    v_ctrl_ok := (v_after = 0);
    RAISE EXCEPTION 'ctrl_rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ctrl_rollback' THEN RAISE; END IF;
  END;
  IF NOT v_ctrl_ok THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: a foreign band inside the union was ACCEPTED; the exclusion does not bite';
  END IF;

  -- 5b. And the control undid itself: card 859 is back where it was.
  SELECT count(*) INTO v_bad FROM derm.address_row_map
   WHERE id = 859 AND band_y0_pct = 44.196 AND band_y1_pct = 49.681;
  IF v_bad <> 1 THEN RAISE EXCEPTION 'VERIFY 5b FAILED: the control did not roll back'; END IF;

  -- 6. The exclusion refuses nothing legitimate today.
  WITH cards AS (
    SELECT r.matched_manifest_id AS mid, r.matched_client_id AS cid, r.dump_folder,
           COALESCE(r.stamp_page, r.page) AS pg, b.band_y0_pct AS y0, b.band_y1_pct AS y1
      FROM derm.address_row_map r JOIN derm.v_stamp_row_bands b ON b.id = r.id
     WHERE r.matched_manifest_id IS NOT NULL AND r.matched_client_id IS NOT NULL
       AND r.stamp_placed_at IS NOT NULL
  ), g AS (SELECT mid, cid, dump_folder, pg, min(y0) u0, max(y1) u1 FROM cards GROUP BY 1,2,3,4)
  SELECT count(*) INTO v_bad
    FROM g JOIN cards c ON c.dump_folder = g.dump_folder AND c.pg = g.pg
     AND (c.mid IS DISTINCT FROM g.mid OR c.cid IS DISTINCT FROM g.cid)
     AND c.y0 < g.u1 AND g.u0 < c.y1;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 6 FAILED: % group(s) would be refused by the new exclusion; investigate before shipping', v_bad;
  END IF;

  RAISE NOTICE 'VERIFY ok: exactly 1 document republishes (m1624, now 27.742..44.196 = all three of Casa Neos own rows), election unchanged, foreign-band exclusion bites and refuses nothing today.';
END $do$;

COMMIT;
