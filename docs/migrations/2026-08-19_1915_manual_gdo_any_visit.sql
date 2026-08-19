-- ============================================================================
-- 2026-08-19 19:15 ET  A manual GDO filing may be recorded on ANY visit
-- ============================================================================
-- Fred: "i told you only for the ones with line item 27, make it so it's every visit instead,
-- SC or SA doesn't matter, with or without line item 27"
--
-- He is right, and reading v_derm_portal_queue shows the code-27 gate was never the bot's rule:
-- the queue selects from v_derm_portal_fields filtered ONLY on visit_date >= rpa_launch_cutoff()
-- plus the already-reported / cooldown / lease tests. It does not mention line items at all. I had
-- carried the condition over from the APP's card-display rule and turned a display convention into
-- a write constraint.
--
-- THREE CHANGES, and the second and third are consequences of actually reading the queue.
--
-- 1. THE CODE-27 REQUIREMENT IS GONE. Any completed, non-deleted visit may carry a manual filing.
--
-- 2. THE MANIFEST-LINK HARD BLOCK IS GONE, REPLACED BY AN HONEST FLAG. It was added this afternoon
--    because a filing on an unlinked post-cutoff visit suppresses nothing. That is still TRUE, but
--    it is no longer a reason to REFUSE: under the old scope every eligible visit was a bot
--    candidate, so "cannot suppress" meant "you are being misled". Now most visits are not bot
--    candidates at all - an unlinked visit has no row in v_derm_portal_fields, so it was never in
--    the queue and there is nothing to stop. Blocking those would gut the feature Fred just asked
--    for. The view now exposes `suppresses_bot` so the UI can say plainly whether recording this
--    will stop the bot, which informs the person instead of refusing them.
--
-- 3. 🛑 THE DUPLICATE CHECK IS NOW PER-PERMIT, BECAUSE THE QUEUE'S IS.
--    The queue excludes a manifest only for a matching permit:
--        (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM f.gdo_id)
--    So one filing does NOT cover a second permit on the same property, and refusing a second
--    filing per VISIT would have made a two-permit visit impossible to fully record while its
--    other permit stayed in the queue. Refusal is now keyed the same way the queue keys exclusion:
--    a NULL permit on either side is blanket (it suppresses everything, so it collides with
--    everything), otherwise only the same permit collides. One rule, one definition - the same
--    reason the already-reported predicate was lifted from the queue rather than reinvented.
--
-- WHAT IS DELIBERATELY KEPT: the visit must be completed and not deleted; a confirmation number,
-- a filer email and a non-future date are required; run_id must carry the manual- prefix; the
-- screenshot path must match the visit and run, and the object must EXIST in the bucket; and a
-- multi-permit visit must still say which permit it was filed under, never guess.
--
-- Audit rule 8: functions and a view, no tables, no trigger opt-in required.
-- ============================================================================

BEGIN;
SET LOCAL search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION public.fn_record_manual_gdo_report(
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

  -- 🛑 THE EVIDENCE MUST BE REAL. The regex proves the string is well formed, not that a file is
  -- there. Without this a caller could commit a filing with an invented path, and that row can
  -- suppress a county filing with nothing to show for it. This is also what makes "upload first,
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

REVOKE EXECUTE ON FUNCTION public.fn_record_manual_gdo_report(bigint, text, timestamptz, text, text, text, bigint) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.fn_record_manual_gdo_report(bigint, text, timestamptz, text, text, text, bigint) FROM anon;
REVOKE ALL     ON FUNCTION public.fn_record_manual_gdo_report(bigint, text, timestamptz, text, text, text, bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_record_manual_gdo_report(bigint, text, timestamptz, text, text, text, bigint) TO service_role;

-- ---- the eligibility view follows the same rule -----------------------------------------------
-- has_code27 is KEPT as an informational column (the card still likes to know) but no longer gates
-- anything. suppresses_bot is new and appended LAST, because CREATE OR REPLACE VIEW may only add
-- columns at the end.
CREATE OR REPLACE VIEW derm.visit_gdo_manual_eligibility AS
SELECT
  v.id AS visit_id,
  EXISTS (SELECT 1 FROM public.line_items li
           WHERE li.visit_id = v.id
             AND (li.name = '27 - GDO Online Reporting' OR li.name ILIKE 'GDO Report%')) AS has_code27,
  EXISTS (SELECT 1 FROM public.derm_portal_submissions s
           WHERE s.visit_id = v.id AND s.dry_run IS NOT TRUE
             AND (s.status = 'SUCCESS' OR s.portal_confirmation IS NOT NULL))            AS already_filed,
  EXISTS (SELECT 1 FROM public.derm_portal_submissions s
           WHERE s.visit_id = v.id AND s.dry_run IS NOT TRUE
             AND s.status <> 'SUCCESS' AND s.portal_confirmation IS NULL)                AS has_failed_attempt,
  (v.visit_date >= public.rpa_launch_cutoff())                                           AS post_cutoff,
  EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.visit_id = v.id)              AS has_manifest_link,
  CASE
    WHEN v.visit_status <> 'completed' THEN 'This visit is not completed yet.'
    WHEN EXISTS (SELECT 1 FROM public.derm_portal_submissions s
                  WHERE s.visit_id = v.id AND s.dry_run IS NOT TRUE
                    AND (s.status = 'SUCCESS' OR s.portal_confirmation IS NOT NULL))
      THEN 'This visit already has a report on record.'
    ELSE NULL
  END AS blocked_reason,
  (
    v.visit_status = 'completed'
    AND NOT EXISTS (SELECT 1 FROM public.derm_portal_submissions s
                     WHERE s.visit_id = v.id AND s.dry_run IS NOT TRUE
                       AND (s.status = 'SUCCESS' OR s.portal_confirmation IS NOT NULL))
  ) AS can_record_manual,
  (SELECT count(DISTINCT f.gdo_id) FROM public.v_derm_portal_fields f
    WHERE f.visit_id = v.id AND f.gdo_id IS NOT NULL)::int AS permit_count,
  -- Whether recording a filing here actually stops the bot. The bot only ever works from
  -- v_derm_portal_fields (manifest + permit) on or after the cutoff, so a visit that is pre-cutoff
  -- or has no manifest link was never a candidate and there is nothing to suppress. This is
  -- INFORMATION for the UI, not a gate: Fred wants the action available on every visit.
  (v.visit_date >= public.rpa_launch_cutoff()
   AND EXISTS (SELECT 1 FROM public.v_derm_portal_fields f WHERE f.visit_id = v.id)) AS suppresses_bot
FROM public.visits v
WHERE v.deleted_at IS NULL;

GRANT SELECT ON derm.visit_gdo_manual_eligibility TO authenticated, service_role;

COMMIT;
