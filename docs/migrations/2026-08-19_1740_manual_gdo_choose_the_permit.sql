-- ============================================================================
-- 2026-08-19 17:40 ET  A manual filing must say WHICH GDO permit it was filed under
-- ============================================================================
-- 🛑 THE BUG THIS FIXES WAS MINE, AND IT WAS SILENT. The function resolved the permit with
--     SELECT f.manifest_id, f.gdo_id INTO ... FROM v_derm_portal_fields f
--      WHERE f.visit_id = p_visit_id LIMIT 1;
-- An unordered LIMIT 1 over a set that is not guaranteed to have one element. I wrote it assuming
-- one permit per visit. Measured instead of assumed:
--
--   eligible visits with 2-3 GDO permits : 12
--   eligible visits with exactly 1       : 15
--   eligible visits with NO permit row   :  2   (1297, 4960)
--
-- 44% of them. Visit 5786 - the one I picked as the happy-path test - carries THREE permits
-- (GDO-10877, GDO-15062, GDO-16389) while its visit page displays only GDO-10877, so the defect was
-- invisible from the UI and the test visit would have "passed" while recording an arbitrary permit.
--
-- Recording the wrong permit is worse than recording nothing: the row still suppresses the bot, so
-- the permit that was actually filed looks handled and the one that was not never gets filed.
--
-- THE RULE NOW:
--   0 permits  -> p_gdo_id must be NULL. Nothing to choose. The filing is still recorded.
--   1 permit   -> p_gdo_id may be NULL and is filled in. Callers do not have to care.
--   2+ permits -> p_gdo_id is REQUIRED and must be one of THIS visit's permits. No default, no
--                 first-row guess. The person filing knows which permit they used; the database
--                 does not, and must not pretend to.
--
-- ⚠ WHAT THIS DOES NOT DO. It does not decide whether a three-permit property needs three separate
-- filings. That is the open shared-blocks / multi-GDO question and it needs Fred. This change only
-- stops us from silently guessing, which is the part that is wrong under every possible answer to
-- that question.
--
-- The 6-argument version is DROPPED rather than left alongside: a 7th argument with a DEFAULT would
-- be an overload, and a 6-named-argument call would then match both and fail as "not unique".
-- Only record-manual-gdo-report calls this, and it is redeployed with the same change.
-- ============================================================================

BEGIN;
SET LOCAL search_path = public, pg_catalog;

DROP FUNCTION IF EXISTS public.fn_record_manual_gdo_report(bigint, text, timestamptz, text, text, text);

CREATE FUNCTION public.fn_record_manual_gdo_report(
  p_visit_id        bigint,
  p_confirmation    text,
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
BEGIN
  SELECT v.visit_date INTO v_vdate FROM public.visits v
   WHERE v.id = p_visit_id AND v.deleted_at IS NULL AND v.visit_status = 'completed';
  IF v_vdate IS NULL THEN
    RAISE EXCEPTION 'visit % does not exist, is deleted, or is not completed', p_visit_id
      USING errcode = '22023';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.line_items li
                  WHERE li.visit_id = p_visit_id
                    AND (li.name = '27 - GDO Online Reporting' OR li.name ILIKE 'GDO Report%')) THEN
    RAISE EXCEPTION 'visit % carries no GDO Online Reporting line item', p_visit_id
      USING errcode = '22023';
  END IF;

  -- Only a row that actually REACHED the county blocks a manual filing. Same predicate
  -- v_derm_portal_queue uses for "already reported"; a failed attempt filed nothing.
  IF EXISTS (SELECT 1 FROM public.derm_portal_submissions s
              WHERE s.visit_id = p_visit_id AND s.dry_run IS NOT TRUE
                AND (s.status = 'SUCCESS' OR s.portal_confirmation IS NOT NULL)) THEN
    RAISE EXCEPTION 'visit % already has a filing on record; use the correction path instead', p_visit_id
      USING errcode = '23505';
  END IF;

  -- 🛑 A POST-CUTOFF visit with no manifest link cannot suppress the bot, because the queue
  -- reaches submissions through manifest_visits. Recording one would look filed here and
  -- still be filed again with the county. Pre-cutoff visits are exempt: the date gate
  -- already keeps the bot away from them.
  IF v_vdate >= public.rpa_launch_cutoff()
     AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.visit_id = p_visit_id) THEN
    RAISE EXCEPTION 'visit % has no linked manifest, so recording a manual filing would NOT stop the bot filing it again. Link the manifest first.', p_visit_id
      USING errcode = '22023';
  END IF;

  IF coalesce(btrim(p_confirmation), '') = '' THEN
    RAISE EXCEPTION 'a confirmation number is required for a manual filing' USING errcode = '22023';
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

  -- 🛑 THE EVIDENCE MUST BE REAL. The regex above proves the string is well formed, not that a file
  -- is there. Without this, a caller could commit a filing with an invented path, and that row
  -- removes the visit from the bot's queue permanently with nothing to show for it. This is also
  -- what makes "upload first, then the row" a rule rather than a comment.
  IF NOT EXISTS (SELECT 1 FROM storage.objects o
                  WHERE o.bucket_id = 'rpa-evidence' AND o.name = p_screenshot_path) THEN
    RAISE EXCEPTION 'no screenshot is stored at rpa-evidence/%. Upload the evidence before recording the filing.', p_screenshot_path
      USING errcode = '22023';
  END IF;

  -- ---- WHICH PERMIT --------------------------------------------------------------------------
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

  -- manifest is resolved WITH the chosen permit, so the two always describe the same filing
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
     btrim(p_confirmation), p_attempted_at, p_screenshot_path, btrim(p_filed_by_email))
  RETURNING * INTO v_row;

  RETURN v_row;
END
$function$;

-- Named explicitly. REVOKE ... FROM PUBLIC does NOT remove the default-privileges grant.
REVOKE EXECUTE ON FUNCTION public.fn_record_manual_gdo_report(bigint, text, timestamptz, text, text, text, bigint) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.fn_record_manual_gdo_report(bigint, text, timestamptz, text, text, text, bigint) FROM anon;
REVOKE ALL     ON FUNCTION public.fn_record_manual_gdo_report(bigint, text, timestamptz, text, text, text, bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_record_manual_gdo_report(bigint, text, timestamptz, text, text, text, bigint) TO service_role;

COMMIT;
