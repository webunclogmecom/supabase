-- ============================================================================
-- 2026-08-19 16:25 ET  A FAILED bot attempt must not block a manual filing
-- ============================================================================
-- Found while building the UI, by reading the real rows instead of the schema.
--
-- Visit 6617 is the case that exposed it. Its property carries TWO GDO permits, and the bot has now
-- attempted it five times:
--     08-07 SUCCESS
--     08-11 / 08-14 / 08-18 / 08-19  ERROR_LOGIN_FAILED, all four identical:
--       "Login failed for permit 11024 - Either the Password or GDO Permit # is incorrect"
-- Four consecutive failures on the same bad credential, and it will keep failing until a person
-- files that permit by hand. That is precisely the situation this feature exists for.
--
-- 🛑 THE BUG: my guard refused a manual filing when ANY live row existed. An ERROR row is NOT a
-- filing - nothing reached Miami-Dade - yet it would have blocked the manual path with
-- "already has a filing on record". The feature would have locked itself out of its own use case.
--
-- THE FIX: use the SAME predicate the bot's queue uses to decide "already reported":
--     status = 'SUCCESS' OR portal_confirmation IS NOT NULL
-- One rule, one definition. If v_derm_portal_queue would still hand this manifest to the bot, a
-- person is still allowed to file it and record that they did.
--
-- Measured before applying: 0 visits are in the all-attempts-failed state TODAY (6617 is excluded
-- because its first attempt succeeded; every other visit is 1 attempt / 1 filing). So this changes
-- no existing row - it removes a latent blocker that fires the first time a bot run errors out
-- without a prior success. Control for that zero: the same grouping without the filter returns
-- 6617 = 5 attempts / 1 filing / 4 failed, so the query could see the shape it reported none of.
--
-- ⚠ NOT SOLVED HERE, deliberately: 6617 shows the multi-GDO problem (two permits, one address ->
-- the card fans out to 10 rows). "The visit is filed" is ambiguous when one permit succeeded and
-- another failed. That is the open shared-blocks / multi-GDO brainstorm and needs Fred, not a
-- guard change.
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

  -- Only a row that actually REACHED the county blocks a manual filing. This is the same
  -- predicate v_derm_portal_queue uses for "already reported" - see the migration header.
  -- A failed attempt (ERROR_LOGIN_FAILED and friends) filed nothing and must not block.
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
