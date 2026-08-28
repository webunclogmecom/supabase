-- 2026-08-28_2110_record_page_rules_defaults_the_etag.sql
--
-- 🛑 A DEFECT IN WHAT I SHIPPED TODAY, AND IT IS THE EXACT TRAP CLAUDE.md ALREADY WARNS ABOUT.
-- ---------------------------------------------------------------------------
-- `derm.record_page_rules` (2026-08-28_1520) reads the image etag out of the caller's meta:
--     v_etag := p_meta->>'source_etag';
-- The Stamp Studio does not send one, so every page measured through the app today landed with
-- `page_rule_scans.source_etag = NULL`.
--
-- WHY THAT MATTERS. `derm.v_band_edge_check.edge_verdict` tests
--     source_etag IS DISTINCT FROM derm._img_etag(doc_source_url)
-- BEFORE it looks at any edge gap, and **NULL IS DISTINCT FROM EVERYTHING**. So a scan row with no
-- etag reports "the image changed under this scan" for every band on that page, when nothing
-- changed. CLAUDE.md records this verbatim: "AN OMITTED source_etag MAKES EVERY BAND READ STALE ...
-- Always populate it." I wrote the RPC anyway without defaulting it.
--
-- WHAT IT COST. Measured before this migration: 4 of 172 scan rows carry a NULL etag and all four are
-- the ones written today (source `runlen-v2-2026-08-28`); the 165 rows from 2026-08-21 and the 3 from
-- 2026-08-27 all have one. `derm.v_band_edges_off_rule` went from **2 rows to 15** as ticket-312024
-- and ticket-312433 started serving, and **13 of the 15 are `edge_verdict = STALE`**, not OFF_RULE.
-- Their actual edge gaps are 0.000 to 0.240pp, comfortably inside the 0.35pp ON_RULE tolerance, and
-- their slot verdicts are ONE_CLIENT. The geometry was never wrong. The worklist was.
--
-- ⚠ That is the failure mode this estate cares about most: a health view whose whole value is
-- "empty means healthy" filling up with rows that are not findings. It is how sync_log became
-- unreadable.
--
-- THE FIX: the RPC computes the etag ITSELF when the caller does not supply one, so no client can
-- forget it again. `derm._img_etag` is a pure SQL lookup against storage.objects, no HTTP, so it is
-- safe to call inline. An explicit meta value still wins, for a caller that legitimately knows better.
--
-- Also backfills the 4 rows already written.
--
-- 🛑 NOT FIXED HERE, and it is a separate question: 3 of the 15 rows are `slot_verdict = ODD_SLOT`
-- on ticket-312433's three 009-CN cards. Those are the multi-GDO split meeting `expected_slots`,
-- which counts every printed row a CLIENT owns on the page (3 for Casa Neos) while each of its cards
-- covers exactly ONE row. Each band is correct; the grader's expectation is what does not fit the
-- per-permit model. Left alone deliberately rather than tuned in a migration about etags.
--
-- RULE 8 (audit trail): `page_rule_scans` is detector output and is opt-out, consistent with
-- 2026-08-28_1520. The backfill writes only the etag of the image each row already names.

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 1. Default the etag inside the RPC.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.record_page_rules(
  p_dump_folder    text,
  p_effective_page integer,
  p_source         text,
  p_source_url     text,
  p_rules          jsonb,
  p_meta           jsonb DEFAULT '{}'::jsonb,
  p_force          boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = derm, public, pg_temp
AS $fn$
DECLARE
  v_grade      text := coalesce(p_meta->>'grade', 'FAILED');
  v_detail     text := p_meta->>'detail';
  -- 🛑 COMPUTE THE ETAG WHEN THE CALLER OMITS IT. A NULL here makes every band on the page read
  -- STALE in v_band_edge_check, because that check compares the etag BEFORE it compares any edge
  -- and NULL is DISTINCT FROM everything. The app does not send one; this is why it must not matter.
  v_etag       text := coalesce(p_meta->>'source_etag', derm._img_etag(p_source_url));
  v_reject     text;
  v_prev       record;
  v_n_rules    integer := 0;
  v_n_bounds   integer := 0;
  v_pitch      numeric;
  v_wrote      boolean := false;
BEGIN
  IF p_source IS NULL OR p_source NOT LIKE 'runlen-v2-%' THEN
    RAISE EXCEPTION 'source must match runlen-v2-%%, got %', coalesce(p_source,'<null>')
      USING ERRCODE = '22023';
  END IF;
  IF p_dump_folder IS NULL OR p_effective_page IS NULL THEN
    RAISE EXCEPTION 'dump_folder and effective_page are required' USING ERRCODE = '22023';
  END IF;
  IF v_grade NOT IN ('OK','IRREGULAR','SPARSE','FAILED') THEN
    RAISE EXCEPTION 'grade % is outside the allowed vocabulary', v_grade USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM derm.address_row_map r
                  WHERE r.dump_folder = p_dump_folder
                    AND coalesce(r.stamp_page, r.page) = p_effective_page) THEN
    RAISE EXCEPTION 'no cards on %/% : refusing to record rules for a page that does not exist',
      p_dump_folder, p_effective_page USING ERRCODE = '22023';
  END IF;

  SELECT s.grade, s.source, s.source_etag, s.scanned_at
    INTO v_prev
    FROM derm.page_rule_scans s
   WHERE s.dump_folder = p_dump_folder AND s.effective_page = p_effective_page
     AND s.source LIKE 'runlen-v2-%'
   ORDER BY s.scanned_at DESC
   LIMIT 1;

  IF FOUND AND v_prev.grade = 'OK' AND v_grade = 'FAILED' AND NOT p_force
     AND (v_etag IS NULL OR v_prev.source_etag IS NULL OR v_etag = v_prev.source_etag) THEN
    RETURN jsonb_build_object(
      'wrote', false, 'grade', v_grade, 'rules_written', 0,
      'skipped', 'would_supersede_ok',
      'detail', format('this page already has an OK scan (%s) and the image has not changed; '
                       || 'refusing to replace it with a %s result', v_prev.source, v_grade));
  END IF;

  IF v_grade <> 'FAILED' THEN
    v_reject := derm.fn_validate_page_rules(p_rules);
    IF v_reject IS NOT NULL THEN
      v_grade  := 'FAILED';
      v_detail := 'rejected by fn_validate_page_rules: ' || v_reject;
    END IF;
  END IF;

  SELECT count(*), count(*) FILTER (WHERE e->>'kind' = 'boundary')
    INTO v_n_rules, v_n_bounds
    FROM jsonb_array_elements(coalesce(p_rules,'[]'::jsonb)) e;

  IF v_grade <> 'FAILED' THEN
    WITH b AS (
      SELECT (e->>'pct')::numeric AS pct
        FROM jsonb_array_elements(p_rules) e
       WHERE e->>'kind' = 'boundary'
       ORDER BY 1
    ), g AS (
      SELECT pct - lag(pct) OVER (ORDER BY pct) AS gap FROM b
    )
    SELECT percentile_disc(0.5) WITHIN GROUP (ORDER BY gap) INTO v_pitch FROM g WHERE gap IS NOT NULL;
  END IF;

  INSERT INTO derm.page_rule_scans
    (dump_folder, effective_page, source_url, image_w, image_h, skew,
     n_rules, n_boundaries, pitch_pct, grade, detail, source, scanned_at, source_etag, skew_saturated)
  VALUES
    (p_dump_folder, p_effective_page, coalesce(p_source_url,'(unknown)'),
     (p_meta->>'image_w')::int, (p_meta->>'image_h')::int, (p_meta->>'skew')::numeric,
     v_n_rules, v_n_bounds, v_pitch, v_grade, v_detail, p_source, now(), v_etag,
     coalesce((p_meta->>'skew_saturated')::boolean, false))
  ON CONFLICT (dump_folder, effective_page, source) DO UPDATE
    SET source_url = EXCLUDED.source_url, image_w = EXCLUDED.image_w, image_h = EXCLUDED.image_h,
        skew = EXCLUDED.skew, n_rules = EXCLUDED.n_rules, n_boundaries = EXCLUDED.n_boundaries,
        pitch_pct = EXCLUDED.pitch_pct, grade = EXCLUDED.grade, detail = EXCLUDED.detail,
        scanned_at = EXCLUDED.scanned_at, source_etag = EXCLUDED.source_etag,
        skew_saturated = EXCLUDED.skew_saturated;

  IF v_grade <> 'FAILED' THEN
    DELETE FROM derm.page_row_rules
     WHERE dump_folder = p_dump_folder AND effective_page = p_effective_page AND source = p_source;
    INSERT INTO derm.page_row_rules
      (dump_folder, effective_page, rule_pct, ink_frac, source, detected_at, run_frac, kind, kind_confirmed)
    SELECT p_dump_folder, p_effective_page,
           (e->>'pct')::numeric, coalesce((e->>'ink')::numeric, 0), p_source, now(),
           (e->>'run')::numeric, e->>'kind', false
      FROM jsonb_array_elements(p_rules) e;
    v_wrote := true;
  END IF;

  RETURN jsonb_build_object(
    'wrote', v_wrote, 'grade', v_grade,
    'rules_written', CASE WHEN v_wrote THEN v_n_rules ELSE 0 END,
    'n_boundaries', v_n_bounds, 'pitch', v_pitch, 'detail', v_detail,
    'source_etag', v_etag);
END $fn$;

-- ---------------------------------------------------------------------------
-- PART 2. Backfill the four rows already written without one.
-- ---------------------------------------------------------------------------
UPDATE derm.page_rule_scans s
   SET source_etag = derm._img_etag(s.source_url)
 WHERE s.source_etag IS NULL
   AND derm._img_etag(s.source_url) IS NOT NULL;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_null integer; v_wl integer; v_stale integer; v_res jsonb; v_docs integer;
BEGIN
  -- 1. No scan row is left without an etag.
  SELECT count(*) INTO v_null FROM derm.page_rule_scans WHERE source_etag IS NULL;
  IF v_null <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % scan row(s) still have a NULL etag', v_null;
  END IF;

  -- 2. 🛑 THE POINT: no band reads STALE any more.
  SELECT count(*) INTO v_stale FROM derm.v_band_edge_check WHERE edge_verdict = 'STALE';
  IF v_stale <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: % band(s) still read STALE', v_stale;
  END IF;

  -- 3. The worklist shrank back toward the two known ticket-830714 rows. It may still carry the
  --    3 ODD_SLOT rows on ticket-312433's multi-permit client, which this migration deliberately
  --    does not touch, so assert a ceiling rather than an exact number.
  SELECT count(*) INTO v_wl FROM derm.v_band_edges_off_rule;
  IF v_wl > 5 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: worklist still has % rows, expected at most 5: %', v_wl,
      (SELECT string_agg(dump_folder||' p'||effective_page||' '||client_code||' '||edge_verdict||'/'||slot_verdict, ', ')
         FROM derm.v_band_edges_off_rule);
  END IF;

  -- 4. 🛑 THE CONTROL. A NEW recording with no meta etag must now get one by itself, or the fix is
  --    cosmetic. Rolled back.
  BEGIN
    v_res := derm.record_page_rules('ticket-312024', 1, 'runlen-v2-etag-probe',
      'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1741/address_1.jpg',
      (SELECT jsonb_agg(jsonb_build_object('pct',rule_pct,'run',run_frac,'ink',ink_frac,'kind',kind)
                        ORDER BY rule_pct)
         FROM derm.v_page_printed_rules WHERE dump_folder='ticket-312024' AND effective_page=1),
      '{"grade":"OK"}'::jsonb);
    IF (v_res->>'source_etag') IS NULL THEN
      RAISE EXCEPTION 'VERIFY 4 FAILED: a recording without a meta etag still produced NULL';
    END IF;
    RAISE EXCEPTION 'probe_rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'probe_rollback' THEN RAISE; END IF;
  END;

  -- 5. Nothing published changed, and the served estate is still clean.
  SELECT count(*) INTO v_docs FROM derm.v_served_blackout_short;
  IF v_docs <> 0 THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: % served document(s) went short', v_docs;
  END IF;

  RAISE NOTICE 'VERIFY ok: 0 scans without an etag, 0 STALE bands, worklist down to % row(s), and a '
    'fresh recording now derives its own etag.', v_wl;
END $do$;

COMMIT;
