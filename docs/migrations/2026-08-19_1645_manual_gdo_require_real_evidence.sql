-- ============================================================================
-- 2026-08-19 16:45 ET  A manual filing must point at a screenshot that EXISTS
-- ============================================================================
-- Found while wiring the edge function, by checking the grant I thought I had set rather than
-- trusting the migration that set it.
--
-- 🛑 HOLE 1 - THE REVOKE DID NOT DO WHAT THE MIGRATION SAID. 2026-08-19_1558 ended with
--     REVOKE ALL ON FUNCTION ... FROM PUBLIC;
--     GRANT EXECUTE ON FUNCTION ... TO service_role;
-- and I read that as "service_role only". The live ACL says otherwise:
--     {postgres=X/postgres, authenticated=X/postgres, service_role=X/postgres}
-- REVOKE FROM PUBLIC removes the PUBLIC entry (=X) and nothing else. The authenticated grant comes
-- from this database's ALTER DEFAULT PRIVILEGES and is a SEPARATE, explicit entry that survives it.
-- This is the trap already recorded in reference_supabase_function_default_privileges, and I walked
-- into it anyway because I checked the SQL I wrote instead of has_function_privilege.
--
-- 🛑 HOLE 2 - AND THAT MATTERS BECAUSE THE PATH CHECK IS SHAPE-ONLY. The function validated
--     p_screenshot_path ~ '^<visit_id>/<run_id>\.(jpg|png)$'
-- which proves the string is well formed, NOT that any file is there. Together the two holes mean a
-- signed-in staff member could call the RPC straight from the browser, pass an invented path and an
-- arbitrary p_filed_by_email, and commit a filing with NO evidence behind it. The
-- derm_portal_submissions_evidence CHECK is satisfied because screenshot_path is non-null. That row
-- then removes the visit from the bot's queue PERMANENTLY. Evidence-free suppression of a county
-- filing is the exact outcome the upload-first ordering exists to prevent, reachable by skipping
-- the edge function entirely.
--
-- THE FIX, both halves, because either alone is weak:
--   1. REVOKE EXECUTE FROM authenticated. Only the edge function (service_role) may call it.
--   2. Require the storage object to actually exist. This is the half that survives someone
--      re-granting EXECUTE later, and it turns "upload first, then the row" from a convention
--      written in a comment into a rule the database enforces. The edge function already uploads
--      before it calls this, so the ordering is unchanged.
--
-- WHY NOT MATCH fn_correct_gdo_report, which IS granted to authenticated on purpose: correcting an
-- existing filing cannot create a suppression that was not already there. Creating one can. The two
-- functions have different blast radii and should not have the same grant.
--
-- Verified after applying: has_function_privilege('authenticated', ...) = false while
-- service_role = true, and a filing quoting a non-existent path is refused while the same call with
-- a real object is accepted.
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

-- Named explicitly. REVOKE ... FROM PUBLIC does NOT remove this entry - that is the whole finding.
REVOKE EXECUTE ON FUNCTION public.fn_record_manual_gdo_report(bigint, text, timestamptz, text, text, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.fn_record_manual_gdo_report(bigint, text, timestamptz, text, text, text) FROM anon;
REVOKE ALL     ON FUNCTION public.fn_record_manual_gdo_report(bigint, text, timestamptz, text, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_record_manual_gdo_report(bigint, text, timestamptz, text, text, text) TO service_role;

COMMIT;
