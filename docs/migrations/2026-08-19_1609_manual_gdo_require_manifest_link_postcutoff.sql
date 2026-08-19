-- ============================================================================
-- 2026-08-19  Refuse a manual filing that could not actually stop the bot
-- ============================================================================
-- Found by probing the queue's exclusion logic rather than reading it.
--
-- v_derm_portal_queue decides "already reported" like this:
--     NOT EXISTS (SELECT 1 FROM derm_portal_submissions s
--                   JOIN manifest_visits smv ON smv.visit_id = s.visit_id
--                  WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run
--                    AND (s.status='SUCCESS' OR s.portal_confirmation IS NOT NULL) ...)
--
-- 🛑 IT REACHES THE SUBMISSION THROUGH manifest_visits. A submission whose visit has NO
-- manifest link therefore joins to nothing, the EXISTS is false, and the manifest is NOT
-- excluded. So a manual filing on an unlinked POST-cutoff visit would be recorded, would
-- look filed in the app, and the bot would STILL file it with Miami-Dade - the exact
-- double-filing this whole feature has to avoid.
--
-- Measured today: ZERO post-cutoff code-27 visits lack a manifest link, so this guard costs
-- nothing now and closes the hole before it opens.
--
-- PRE-cutoff visits are deliberately exempt: the queue excludes them by date
-- (visit_date >= rpa_launch_cutoff()) whatever they carry, so an unlinked pre-cutoff visit
-- cannot be double-filed and the 29-visit backfill must not be blocked by this.
-- ============================================================================

BEGIN;
SET LOCAL search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION public.fn_record_manual_gdo_report(
  p_visit_id        bigint,
  p_confirmation    text,
  p_attempted_at    timestamptz,
  p_run_id          text,
  p_screenshot_path text,
  p_filed_by_email  text
) RETURNS public.derm_portal_submissions
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE v_row public.derm_portal_submissions; v_manifest bigint; v_gdo bigint; v_vdate date;
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

  IF EXISTS (SELECT 1 FROM public.derm_portal_submissions s
              WHERE s.visit_id = p_visit_id AND s.dry_run IS NOT TRUE) THEN
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

  SELECT f.manifest_id, f.gdo_id INTO v_manifest, v_gdo
    FROM public.v_derm_portal_fields f WHERE f.visit_id = p_visit_id LIMIT 1;

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

REVOKE ALL ON FUNCTION public.fn_record_manual_gdo_report(bigint, text, timestamptz, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_record_manual_gdo_report(bigint, text, timestamptz, text, text, text) TO service_role;

COMMIT;
