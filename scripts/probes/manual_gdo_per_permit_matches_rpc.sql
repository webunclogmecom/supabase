-- ============================================================================
-- derm.visit_gdo_our_record.can_record_manual MUST agree with the real function,
-- PER (visit, permit) PAIR.  Everything rolls back.
--   node scripts/q.js scripts/probes/manual_gdo_per_permit_matches_rpc.sql <out.json>
--
-- WHY THIS EXISTS SEPARATELY FROM manual_gdo_view_matches_rpc.sql, which passes and is not enough:
-- that probe compares the VISIT-level view (derm.visit_gdo_manual_eligibility) with the function.
-- On 2026-08-20 both said "no" for visit 6617 while the function would happily have accepted a
-- filing for permit GDO-11024 - they agreed on the ANSWER and disagreed on the QUESTION. The app
-- hid the "Record a manual filing" button on the one permit that needed it, never filed, 16 days
-- old. Two wrongs reading as an agreement.
--
--   view says yes / RPC refuses  -> the person fills the form and the submit errors
--   view says no  / RPC accepts  -> the button is missing on a permit that needs it  <- the real one
--
-- The DISAGREEING-PERMITS control is the point of the file. A visit where one permit is filed and
-- another is not is the only shape that can distinguish per-visit from per-permit reasoning, so if
-- zero such visits were exercised this probe proves nothing and must fail loudly.
--
-- ⚠ THE SPLIT-VISIT CONTROL WILL FAIL ONE DAY, AND THAT IS CORRECT. DO NOT DELETE IT.
-- Measured 2026-08-20: **exactly ONE** visit in the database has disagreeing permits (6617), and
-- the whole reason it does is that GDO-11024 has never been filed. The moment somebody files it,
-- split_visits drops to 0 and this probe stops with CONTROL FAILED rather than PASSED. That is the
-- instrument refusing to claim proof it no longer has - not a regression, and not something to
-- "fix" by removing the assertion. Restore coverage by arranging the shape inside the transaction
-- (file one permit of a 2-permit visit, leave the other) rather than by lowering the bar.
--
-- SIGNATURE (p_confirmation removed 2026-08-20):
--   fn_record_manual_gdo_report(visit_id, attempted_at, run_id, screenshot_path, filed_by_email, gdo_id)
-- ============================================================================
DO $perm$
DECLARE
  r record; v_run text; v_path text; v_bucket text;
  predicted bool; actual bool; err text;
  n int := 0; mismatches int := 0; yes_ok int := 0; no_ok int := 0;
  split_visits int := 0; multi int := 0;
  first_bad text;
BEGIN
  SELECT id INTO v_bucket FROM storage.buckets WHERE name = 'rpa-evidence';

  -- visits whose permits DISAGREE: at least one filed and at least one not. This is the shape the
  -- per-visit view cannot represent, and the shape the 6617 defect lived in.
  SELECT count(*) INTO split_visits FROM (
    SELECT o.visit_id FROM derm.visit_gdo_our_record o
      JOIN public.visits v ON v.id = o.visit_id AND v.visit_status = 'completed'
     GROUP BY o.visit_id
    HAVING bool_or(o.filed_for_this_permit) AND bool_or(NOT o.filed_for_this_permit)
  ) s;

  FOR r IN
    SELECT o.visit_id, o.gdo_id, o.gdo_number, o.can_record_manual,
           count(*) OVER (PARTITION BY o.visit_id) AS permits_on_visit
      FROM derm.visit_gdo_our_record o
      JOIN public.visits v ON v.id = o.visit_id
     WHERE v.visit_status = 'completed' AND o.gdo_id IS NOT NULL
     ORDER BY o.visit_id, o.gdo_id
  LOOP
    n := n + 1;
    predicted := r.can_record_manual;
    IF r.permits_on_visit > 1 THEN multi := multi + 1; END IF;

    v_run  := 'manual-perm' || r.visit_id::text || '-' || r.gdo_id::text;
    v_path := r.visit_id::text || '/' || v_run || '.jpg';
    INSERT INTO storage.objects (bucket_id, name, metadata)
    VALUES (v_bucket, v_path, '{"mimetype":"image/jpeg","size":1}'::jsonb)
    ON CONFLICT DO NOTHING;

    BEGIN
      PERFORM public.fn_record_manual_gdo_report(
        r.visit_id, now() - interval '1 hour', v_run, v_path, 'fred@ayache.com', r.gdo_id);
      actual := true;
    EXCEPTION WHEN others THEN actual := false; err := SQLERRM; END;

    -- undo, so the next permit on the same visit is judged on its own merits
    DELETE FROM public.derm_portal_submissions WHERE visit_id = r.visit_id AND run_id = v_run;

    IF predicted IS DISTINCT FROM actual THEN
      mismatches := mismatches + 1;
      IF first_bad IS NULL THEN
        first_bad := format('visit %s permit %s: view=%s rpc=%s [%s]',
                            r.visit_id, coalesce(r.gdo_number,'?'), predicted, actual, coalesce(err,'-'));
      END IF;
    ELSIF predicted THEN yes_ok := yes_ok + 1;
    ELSE no_ok := no_ok + 1;
    END IF;
  END LOOP;

  RAISE NOTICE '---';
  RAISE NOTICE 'visit-permit pairs checked      : %', n;
  RAISE NOTICE '  agreed, both YES              : %', yes_ok;
  RAISE NOTICE '  agreed, both NO               : %', no_ok;
  RAISE NOTICE '  of which multi-permit visits  : %', multi;
  RAISE NOTICE '  visits with DISAGREEING permits: %', split_visits;
  RAISE NOTICE '  MISMATCHES                    : %', mismatches;

  IF n = 0          THEN RAISE EXCEPTION 'CONTROL FAILED: no visit-permit pair examined at all'; END IF;
  IF yes_ok = 0     THEN RAISE EXCEPTION 'CONTROL FAILED: nothing was accepted, so agreement on YES is unproven'; END IF;
  IF no_ok = 0      THEN RAISE EXCEPTION 'CONTROL FAILED: nothing was refused, so agreement on NO is unproven'; END IF;
  IF multi = 0      THEN RAISE EXCEPTION 'CONTROL FAILED: no multi-permit visit exercised'; END IF;
  IF split_visits=0 THEN RAISE EXCEPTION 'CONTROL FAILED: no visit had one permit filed and another not - the exact case this view exists for was never exercised, so a zero-mismatch result means nothing'; END IF;
  IF mismatches > 0 THEN RAISE EXCEPTION 'FAIL: % pair(s) disagree. first: %', mismatches, first_bad; END IF;

  RAISE EXCEPTION 'PASSED: view and function agree on all % visit-permit pairs (% yes, % no; % split visits) - rolling back', n, yes_ok, no_ok, split_visits;
END $perm$;
