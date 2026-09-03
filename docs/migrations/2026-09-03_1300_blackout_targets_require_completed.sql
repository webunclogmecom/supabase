-- 2026-09-03_1300_blackout_targets_require_completed.sql
--
-- WHY
-- ---
-- The other half of step 3 of `Building Apps/DERM Stamp Studio/docs/11-completion-gated-publish-spec.md`,
-- split out of 2026-09-03_1230 because CREATE OR REPLACE on this function is the riskiest edit in
-- the blackout area and deserves its own revert boundary.
--
-- `derm.fn_blackout_targets` did not read `completed` AT ALL (verified: the word did not appear in
-- its body). So publication was independent of sign-off. With 2026-09-03_1230 now marking a sheet
-- DIRTY whenever a card, stamp or band changes, the missing half is that a dirty sheet must stop
-- REGENERATING until a person signs it off again. Fred, 2026-08-27: "when uncompleting and
-- completing it again it needs to be blackedout again."
--
-- 🛑 THE GATE BELONGS ON REGENERATION, NOT ON SERVING, and that distinction is the whole safety
-- argument. `customer.work_orders` reads `derm.redacted_manifest_docs.url` directly and nothing
-- garbage-collects it, so a dirty sheet KEEPS SERVING the document it already has. Fred's 2026-08-27
-- decision, asked explicitly: withdrawing it would take a working document away from a client who
-- did nothing wrong, and the old sheet is not WRONG for them, merely missing a neighbour added later.
--
-- MEASURED NO-OP AT INSTALL: 136 folders, ALL completed, `fn_blackout_targets(2000)` returns 0 rows,
-- 0 folders with placed stamps but no status row, and 0 serving documents whose folder is not
-- completed. So this refuses nothing today.
-- ⚠ STATE THAT HONESTLY: because it refuses nothing today, the exclusion arm is UNEXERCISED on real
-- data. Its first real exercise is the next sheet that goes dirty. What IS verified below is that
-- the function still runs, that its output is byte-for-byte the same population as before, and that
-- the predicate's own semantics are correct.
--
-- ⚠ The body below was copied byte-for-byte from pg_get_functiondef and patched programmatically
-- (scratchpad/ex2.js), then diffed: SEVEN added lines in an 8,592-byte function and nothing else.
-- It was NOT retyped - see the CREATE OR REPLACE rule in Supabase/CLAUDE.md, which records what
-- retyping this family of function cost on 2026-08-06.
--
-- RULE 8 (audit): no table or column changes; nothing to opt in or out.

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
$function$
;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_n integer; v_ok boolean;
BEGIN
  -- 1. The clause is actually in the deployed body (not just in the file).
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'derm' AND p.proname = 'fn_blackout_targets'
     AND pg_get_functiondef(p.oid) LIKE '%stamp_sheet_status s%s.completed%';
  IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY 1: the completed gate is not in the deployed body'; END IF;

  -- 2. THE FUNCTION STILL RUNS. This is a LANGUAGE sql function, so a syntax error would already
  --    have failed the CREATE, but a semantic break (a missing column after the edit) would not.
  --    Executing it is the only thing that proves the whole CTE chain still resolves.
  SELECT count(*) INTO v_n FROM derm.fn_blackout_targets(2000);
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2: expected the measured no-op (0 targets), got % - investigate before trusting this', v_n;
  END IF;

  -- 3. THE PREDICATE'S OWN SEMANTICS, tested directly rather than assumed. The exclusion arm cannot
  --    be exercised through the function today (nothing is a target), so test the clause itself:
  --    true for a real completed folder, false for a folder that has no status row at all.
  SELECT EXISTS (SELECT 1 FROM derm.stamp_sheet_status s
                  WHERE s.dump_folder = 'ticket-834287' AND s.completed) INTO v_ok;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 3: predicate false for a known completed folder'; END IF;
  SELECT EXISTS (SELECT 1 FROM derm.stamp_sheet_status s
                  WHERE s.dump_folder = '__no_such_folder__' AND s.completed) INTO v_ok;
  IF v_ok THEN RAISE EXCEPTION 'VERIFY 3: predicate true for a non-existent folder'; END IF;

  -- 4. And the install-time premise still holds: every folder carrying a placed stamp has a status
  --    row, so the gate cannot silently strand a folder that simply never had one.
  SELECT count(*) INTO v_n FROM (
    SELECT DISTINCT r.dump_folder FROM derm.address_row_map r WHERE r.stamp_placed_at IS NOT NULL) x
   WHERE NOT EXISTS (SELECT 1 FROM derm.stamp_sheet_status s WHERE s.dump_folder = x.dump_folder);
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 4: % folder(s) with placed stamps have no status row and would be stranded', v_n;
  END IF;

  RAISE NOTICE 'VERIFY ok: gate deployed, function still resolves and returns the same 0-row population, predicate semantics correct both ways, no folder stranded.';
END $do$;

COMMIT;
