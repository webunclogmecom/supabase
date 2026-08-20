-- ============================================================================
-- 2026-08-20 16:20 ET  Stop asking a person for a confirmation number that does not exist
-- ============================================================================
-- Fred: "it asks for a confirmation number, but there is not such a thing".
--
-- He is right, and the whole table proves it. Across all 535 rows portal_confirmation has held
-- exactly THREE values, ever:
--     "Dry run: Preview captured, submit skipped"                521 rows, 0 live
--     "Submitted — DERM portal confirmed (no tracking number)"     7 rows, ALL 7 live successes
--     NULL                                                         7 rows, 4 live (the failures)
-- Every live success carries the SAME literal, and that literal says "no tracking number". Only two
-- distinct string lengths exist in the entire table, which is the signature of a hard-coded constant
-- in the bot's code rather than anything scraped off a county screen. Fred already recorded the
-- same conclusion on 2026-07-24: "The county returns no tracking number and the manifest number is
-- the meaningful identifier ops recognizes."
--
-- 🛑 IT IS A BOOLEAN WEARING A COSTUME. Twelve database objects reference this column and all twelve
-- test IS NULL / IS NOT NULL or project it. Nothing parses it - no regex, no LIKE, no substring. Its
-- only mechanical job is the queue-exit flag in
--     (status = 'SUCCESS' OR portal_confirmation IS NOT NULL)
-- so the form was asking a human to hand-author an implementation detail of a machine-to-machine
-- contract, under a label the county does not issue.
--
-- ⚠ AND IT IS CLIENT-FACING, WHICH IS WHY THE WORDING IS FRED'S CALL AND NOT MINE.
-- customer.gdo_reports selects it as `confirmation`, reaching the Field Portal through the
-- customer.get_work_order allowlist. Measured today: 84 reports across 7 real clients are reading
-- that sentence right now under a heading that says "Confirmation".
--
-- FRED'S DECISION (asked directly, 2026-08-20): a hand-filed report should SAY it was filed
-- manually, and the form should ask for no free text at all.
--
-- WHAT CHANGES
--   1. p_confirmation is REMOVED from the signature. The function now writes a fixed sentence.
--      Removed rather than made optional ON PURPOSE: the value is client copy, so no caller should
--      be able to inject text a paying customer reads.
--   2. The sentence is 'Filed manually, DERM portal confirmed (no tracking number)'. It mirrors the
--      bot's shape so the two read as a family, states plainly that a person filed it, and repeats
--      "no tracking number" so nobody goes looking for one. (No em dash, per Fred's standing rule;
--      the bot's older string has one and is left alone - rewriting live client copy is not part of
--      this change.)
--   3. Nothing else moves. The row is still status='SUCCESS', dry_run=false, so
--      derm_portal_submissions_success_confirmed is satisfied by a non-null value exactly as before,
--      and the queue still sees the visit as reported. This does NOT re-open the queue.
--
-- The 7-argument version is DROPPED rather than left beside the new one: an overload differing only
-- by an argument would make a 6-named-argument call ambiguous. record-manual-gdo-report is the only
-- caller and is redeployed with it.
-- ============================================================================

BEGIN;
SET LOCAL search_path = public, pg_catalog;

DROP FUNCTION IF EXISTS public.fn_record_manual_gdo_report(bigint, text, timestamptz, text, text, text, bigint);

CREATE FUNCTION public.fn_record_manual_gdo_report(
  p_visit_id        bigint,
  p_attempted_at    timestamptz,
  p_run_id          text,
  p_screenshot_path text,
  p_filed_by_email  text,
  p_gdo_id          bigint DEFAULT NULL
) RETURNS public.derm_portal_submissions
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_row      public.derm_portal_submissions;
  v_manifest bigint;
  v_gdo      bigint;
  v_vdate    date;
  v_permits  int;
  -- Client-facing. Changing this sentence changes what a customer reads in the Field Portal.
  c_confirmation constant text := 'Filed manually, DERM portal confirmed (no tracking number)';
BEGIN
  SELECT v.visit_date INTO v_vdate FROM public.visits v
   WHERE v.id = p_visit_id AND v.deleted_at IS NULL AND v.visit_status = 'completed';
  IF v_vdate IS NULL THEN
    RAISE EXCEPTION 'visit % does not exist, is deleted, or is not completed', p_visit_id
      USING errcode = '22023';
  END IF;

  IF coalesce(btrim(p_filed_by_email), '') = '' THEN
    RAISE EXCEPTION 'the filer email is required' USING errcode = '22023';
  END IF;
  IF p_attempted_at IS NULL OR p_attempted_at > now() + interval '1 day' THEN
    RAISE EXCEPTION 'the filing date is required and cannot be in the future' USING errcode = '22023';
  END IF;
  IF p_run_id !~ '^manual-[A-Za-z0-9_.-]{1,90}$' THEN
    RAISE EXCEPTION 'a manual run_id must start with manual- (got %)', p_run_id USING errcode = '22023';
  END IF;
  IF p_screenshot_path IS NULL
     OR p_screenshot_path !~ ('^' || p_visit_id::text || '/' || p_run_id || '\.(jpg|png)$') THEN
    RAISE EXCEPTION 'screenshot_path must be <visit_id>/<run_id>.jpg or .png (got %)', p_screenshot_path
      USING errcode = '22023';
  END IF;

  -- 🛑 THE EVIDENCE MUST BE REAL. The regex proves the string is well formed, not that a file is
  -- there. Without this a caller could commit a filing with an invented path, and that row can
  -- suppress a county filing with nothing to show for it. It is also what makes "upload first,
  -- then the row" a rule rather than a comment.
  IF NOT EXISTS (SELECT 1 FROM storage.objects o
                  WHERE o.bucket_id = 'rpa-evidence' AND o.name = p_screenshot_path) THEN
    RAISE EXCEPTION 'no screenshot is stored at rpa-evidence/%. Upload the evidence before recording the filing.', p_screenshot_path
      USING errcode = '22023';
  END IF;

  -- ---- WHICH PERMIT. Never guessed; see 2026-08-19_1740. ---------------------------------------
  SELECT count(DISTINCT f.gdo_id) INTO v_permits
    FROM public.v_derm_portal_fields f WHERE f.visit_id = p_visit_id AND f.gdo_id IS NOT NULL;

  IF p_gdo_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM public.v_derm_portal_fields f
                    WHERE f.visit_id = p_visit_id AND f.gdo_id = p_gdo_id) THEN
      RAISE EXCEPTION 'GDO permit % does not belong to visit %', p_gdo_id, p_visit_id
        USING errcode = '22023';
    END IF;
    v_gdo := p_gdo_id;
  ELSIF v_permits > 1 THEN
    RAISE EXCEPTION 'visit % has % GDO permits, so the filing must say which one it was filed under', p_visit_id, v_permits
      USING errcode = '22023';
  ELSE
    SELECT f.gdo_id INTO v_gdo FROM public.v_derm_portal_fields f
     WHERE f.visit_id = p_visit_id AND f.gdo_id IS NOT NULL LIMIT 1;
  END IF;

  -- ---- ALREADY FILED, keyed PER PERMIT exactly as v_derm_portal_queue keys exclusion -----------
  IF EXISTS (SELECT 1 FROM public.derm_portal_submissions s
              WHERE s.visit_id = p_visit_id AND s.dry_run IS NOT TRUE
                AND (s.status = 'SUCCESS' OR s.portal_confirmation IS NOT NULL)
                AND (s.gdo_id IS NULL OR v_gdo IS NULL OR s.gdo_id = v_gdo)) THEN
    RAISE EXCEPTION 'visit % already has a filing on record for that GDO permit; use the correction path instead', p_visit_id
      USING errcode = '23505';
  END IF;

  SELECT f.manifest_id INTO v_manifest
    FROM public.v_derm_portal_fields f
   WHERE f.visit_id = p_visit_id
     AND (v_gdo IS NULL OR f.gdo_id = v_gdo)
   ORDER BY f.manifest_id NULLS LAST
   LIMIT 1;

  INSERT INTO public.derm_portal_submissions
    (visit_id, manifest_id, gdo_id, run_id, status, retryable, dry_run,
     portal_confirmation, attempted_at, screenshot_path, filed_by_email)
  VALUES
    (p_visit_id, v_manifest, v_gdo, p_run_id, 'SUCCESS', false, false,
     c_confirmation, p_attempted_at, p_screenshot_path, btrim(p_filed_by_email))
  RETURNING * INTO v_row;

  RETURN v_row;
END
$function$;

REVOKE EXECUTE ON FUNCTION public.fn_record_manual_gdo_report(bigint, timestamptz, text, text, text, bigint) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.fn_record_manual_gdo_report(bigint, timestamptz, text, text, text, bigint) FROM anon;
REVOKE ALL     ON FUNCTION public.fn_record_manual_gdo_report(bigint, timestamptz, text, text, text, bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_record_manual_gdo_report(bigint, timestamptz, text, text, text, bigint) TO service_role;

COMMIT;
