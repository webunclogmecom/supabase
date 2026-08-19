-- ============================================================================
-- 2026-08-19  A manual path for GDO Online Reports filed by a person, not the bot
-- ============================================================================
-- Fred: "what if we do that report manually, where can we submit it? nowhere, so we need
-- to have a manual way to do it at the DERM App."
--
-- THE GAP, measured. The bot's own record is complete: rpa_launch_cutoff() is 2026-07-21,
-- and of the 5 code-27 visits on/after it, 0 are unfiled. The entire gap is the 29
-- COMPLETED code-27 visits BEFORE the cutoff, which the queue view date-gates out and the
-- bot will therefore never touch. Those were filed by hand with the county and there has
-- been nowhere to record it.
--
-- DECISIONS (Fred, 2026-08-19, asked explicitly because both carry real risk):
--   * scope     -> ANY code-27 visit, including post-cutoff, behind a confirm in the UI
--                  that says plainly it stops the bot filing that visit.
--   * evidence  -> SCREENSHOT MANDATORY. He chose this knowing it blocks a historical
--                  backfill that has no image.
--
-- 🛑 WHY THE ROW IS CREATED LAST, AND THIS ORDERING IS THE WHOLE SAFETY ARGUMENT.
-- The submission ROW is what removes a visit from v_derm_portal_queue. Storage RLS
-- (fn_is_gdo_evidence_path) only permits an upload to <visit_id>/<run_id>.jpg|png once a
-- live non-dry-run row EXISTS. Those two facts together forbid the obvious flow: create the
-- row, then upload. That would suppress the bot BEFORE the evidence lands, so a failed
-- upload leaves a visit silently closed with nothing filed at the county.
-- ⇒ The caller (edge function, service role, which bypasses storage RLS) uploads FIRST and
--   calls this function LAST, passing the path it already wrote. If anything fails before
--   this function commits, NO suppression has happened. The worst case is a stranded
--   object, which is recoverable; the worst case of the other ordering is a report that
--   never went to Miami-Dade and that nothing will ever re-queue.
--
-- WHAT MAKES A MANUAL ROW DISTINGUISHABLE FOREVER, two independent markers:
--   1. run_id is forced to the 'manual-' prefix (bot runs never use it; 0 such rows today)
--   2. a new nullable column filed_by_email, NULL on every bot row by construction
-- The second exists because attribution cannot come from audit.logs here: the edge function
-- runs as service_role, so audit.logs would record no user email at all. For compliance
-- evidence "who filed this" has to be stored, not inferred.
--
-- 🛑 status is 'SUCCESS' ON PURPOSE, and that is what suppresses the bot. It is correct:
-- the report DID go in, a human did it. The existing CHECK derm_portal_submissions_success_confirmed
-- then forces portal_confirmation to be present, so a manual SUCCESS without a confirmation
-- number is impossible at the DB layer, not merely discouraged.
--
-- RULE 8 (audit): public.derm_portal_submissions already carries an audit.log_change
-- trigger (verified, 1 trigger). Adding a column to an audited table is captured
-- automatically. No trigger work.
-- ============================================================================

BEGIN;
SET LOCAL search_path = public, pg_catalog;

-- 1. attribution column -----------------------------------------------------------
ALTER TABLE public.derm_portal_submissions
  ADD COLUMN IF NOT EXISTS filed_by_email text;

COMMENT ON COLUMN public.derm_portal_submissions.filed_by_email IS
  'Staff email for a MANUAL filing recorded through fn_record_manual_gdo_report. NULL on every bot row. Attribution cannot come from audit.logs because the edge function runs as service_role.';

-- 2. the only sanctioned write path for a manual filing ---------------------------
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
DECLARE v_row public.derm_portal_submissions; v_manifest bigint; v_gdo bigint; v_ext text;
BEGIN
  -- the visit must exist, be alive and be completed
  IF NOT EXISTS (SELECT 1 FROM public.visits v
                  WHERE v.id = p_visit_id AND v.deleted_at IS NULL
                    AND v.visit_status = 'completed') THEN
    RAISE EXCEPTION 'visit % does not exist, is deleted, or is not completed', p_visit_id
      USING errcode = '22023';
  END IF;

  -- it must actually be billed for online reporting; all four observed name variants
  IF NOT EXISTS (SELECT 1 FROM public.line_items li
                  WHERE li.visit_id = p_visit_id
                    AND (li.name = '27 - GDO Online Reporting' OR li.name ILIKE 'GDO Report%')) THEN
    RAISE EXCEPTION 'visit % carries no GDO Online Reporting line item', p_visit_id
      USING errcode = '22023';
  END IF;

  -- never a second live filing for the same visit; correcting one is fn_correct_gdo_report
  IF EXISTS (SELECT 1 FROM public.derm_portal_submissions s
              WHERE s.visit_id = p_visit_id AND s.dry_run IS NOT TRUE) THEN
    RAISE EXCEPTION 'visit % already has a filing on record; use the correction path instead', p_visit_id
      USING errcode = '23505';
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

  -- 🛑 the marker that keeps manual rows tellable from bot rows forever
  IF p_run_id !~ '^manual-[A-Za-z0-9_.-]{1,90}$' THEN
    RAISE EXCEPTION 'a manual run_id must start with manual- (got %)', p_run_id USING errcode = '22023';
  END IF;

  -- the evidence must already be uploaded, and must sit at the RLS-sanctioned path
  IF p_screenshot_path IS NULL
     OR p_screenshot_path !~ ('^' || p_visit_id::text || '/' || p_run_id || '\.(jpg|png)$') THEN
    RAISE EXCEPTION 'screenshot_path must be <visit_id>/<run_id>.jpg or .png (got %)', p_screenshot_path
      USING errcode = '22023';
  END IF;

  -- carry the manifest / gdo the reporting fields view resolves for this visit, so the
  -- card's "Our record" panel and the queue's already-reported test both behave as they
  -- do for a bot row
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
