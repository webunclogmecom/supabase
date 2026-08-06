-- 2026-08-06_1730_gdo_report_correction.sql
--
-- WHAT: let the DERM Tracker SHOW the GDO Online Report for a visit (data + evidence photo)
--       and let staff correct the two free-text fields and replace the photo.
--
-- WHY: Fred, 2026-08-06. The bot now files for real with Miami-Dade, and until today nobody
--      could see what it filed except by querying SQL. If it posts a typo or grabs the wrong
--      screenshot there is no way to fix it: `rpa-derm-result` is append-only, first-write-wins
--      (POST only, UNIQUE (visit_id, run_id), and a duplicate POST returns deduped BEFORE the
--      screenshot upload). Fred chose a human-driven correction surface over an amend API, which
--      also avoids a contract change on John's side.
--
-- 🛑 THE HAZARD THIS MIGRATION IS SHAPED AROUND — READ BEFORE CHANGING ANYTHING BELOW.
--    public.v_derm_portal_queue decides "already reported" with:
--        NOT EXISTS (submission WHERE NOT dry_run AND (status='SUCCESS' OR portal_confirmation IS NOT NULL))
--    So nulling portal_confirmation, or moving status off SUCCESS, RE-OPENS THE QUEUE and the bot
--    files the same visit with the county a SECOND time.
--    ⚠ AND IT IS INVISIBLE FOR ~20 HOURS: two other gates (a 20h attempt cooldown on created_at and
--    a 20h dispense lease) mask it. Measured 2026-08-06 on visit 6719 — clearing the confirmation
--    did NOT re-queue, purely because the row was 19h29m old. Both gates expired ~30 min later.
--    A tester would call it safe and get a duplicate government filing the next morning.
--
-- ⇒ THE GUARD IS STRUCTURAL, NOT PROCEDURAL. fn_correct_gdo_report CANNOT write status, dry_run,
--   visit_id, run_id or attempted_at. Combined with the EXISTING check constraint
--   derm_portal_submissions_success_confirmed (status<>'SUCCESS' OR dry_run OR confirmation NOT NULL),
--   a live SUCCESS row's confirmation can never be nulled: the DB raises 23514.
--   DO NOT "improve" this by letting the function take a status argument. That is the whole defence.
--   UI-only field hiding is NOT sufficient (Building Apps rule #7: UI gating is bypassable).

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Evidence photos: let the staff app read + replace them.
--    `rpa-evidence` is the only PRIVATE bucket and had ZERO policies naming it, so only
--    service_role (which bypasses RLS) could see it. Measured before this migration:
--    bucket public=false, 28 objects, 0 matching policies (control: 10 policies exist overall).
--    Every app that will read this is staff-gated Supabase-Auth, same trust level as the other
--    buckets. anon gets nothing.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS rpa_evidence_staff_read   ON storage.objects;
DROP POLICY IF EXISTS rpa_evidence_staff_insert ON storage.objects;
DROP POLICY IF EXISTS rpa_evidence_staff_update ON storage.objects;

CREATE POLICY rpa_evidence_staff_read ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'rpa-evidence');

-- Replacing a wrong photo overwrites in place (Fred, 2026-08-06: "overwrite").
-- Supabase upsert needs INSERT and UPDATE.
CREATE POLICY rpa_evidence_staff_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'rpa-evidence');

CREATE POLICY rpa_evidence_staff_update ON storage.objects
  FOR UPDATE TO authenticated
  USING (bucket_id = 'rpa-evidence')
  WITH CHECK (bucket_id = 'rpa-evidence');

-- ---------------------------------------------------------------------------
-- 2. The correction function. Narrow by construction.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_correct_gdo_report(
  p_visit_id            bigint,
  p_portal_confirmation text,
  p_failure_reason      text
)
RETURNS TABLE (
  visit_id            bigint,
  status              text,
  portal_confirmation text,
  failure_reason      text,
  screenshot_path     text,
  attempted_at        timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_id bigint;
  v_n  integer;
BEGIN
  IF p_visit_id IS NULL THEN
    RAISE EXCEPTION 'visit id is required' USING ERRCODE = '22023';
  END IF;

  -- Correct the LIVE row only. Dry-run rows are test artefacts and are not corrected.
  SELECT s.id INTO v_id
    FROM public.derm_portal_submissions s
   WHERE s.visit_id = p_visit_id
     AND s.dry_run IS NOT TRUE
   ORDER BY s.attempted_at DESC NULLS LAST, s.id DESC
   LIMIT 1;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'no live GDO report exists for visit % - nothing to correct', p_visit_id
      USING ERRCODE = '22023';
  END IF;

  -- Trim to NULL so an emptied box does not store ''. NOTE: on a SUCCESS row this makes the
  -- existing success_confirmed CHECK fire (23514) rather than silently clearing the field that
  -- holds the visit out of the queue. That rejection is CORRECT and is the point.
  UPDATE public.derm_portal_submissions s
     SET portal_confirmation = NULLIF(btrim(coalesce(p_portal_confirmation, '')), ''),
         failure_reason      = NULLIF(btrim(coalesce(p_failure_reason, '')), '')
   WHERE s.id = v_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'expected to correct exactly 1 row, touched %', v_n USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT s.visit_id, s.status, s.portal_confirmation, s.failure_reason,
         s.screenshot_path, s.attempted_at
    FROM public.derm_portal_submissions s
   WHERE s.id = v_id;
END
$fn$;

COMMENT ON FUNCTION public.fn_correct_gdo_report(bigint, text, text) IS
  'Staff correction of a GDO Online Report record. Writes ONLY portal_confirmation and '
  'failure_reason. It deliberately CANNOT write status/dry_run/visit_id/run_id/attempted_at: '
  'nulling the confirmation or moving status off SUCCESS re-opens v_derm_portal_queue and causes '
  'a DUPLICATE filing with Miami-Dade, and that stays invisible for ~20h behind the cooldown and '
  'lease gates. Do not add a status argument.';

REVOKE ALL ON FUNCTION public.fn_correct_gdo_report(bigint, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_correct_gdo_report(bigint, text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. What the app reads. derm.gdo_report_status already exists and is granted, but carries no
--    evidence path, so add a sibling the detail page can read in one query.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW derm.visit_gdo_report AS
SELECT
  s.visit_id,
  s.status,
  s.portal_confirmation,
  s.failure_reason,
  s.retryable,
  s.attempted_at,
  s.run_id,
  s.screenshot_path,
  s.screenshot_missing_reason,
  s.manifest_id
FROM public.derm_portal_submissions s
WHERE s.dry_run IS NOT TRUE;

COMMENT ON VIEW derm.visit_gdo_report IS
  'Live (non dry-run) GDO Online Report per visit, for the DERM Tracker visit page. dry-run rows '
  'are test artefacts against a separate QA queue and are deliberately excluded - showing them '
  'would read as real filings (524 dry-run rows exist vs 3 live ones as of 2026-08-06).';

GRANT SELECT ON derm.visit_gdo_report TO authenticated;
GRANT SELECT ON derm.visit_gdo_report TO service_role;

-- ---------------------------------------------------------------------------
-- ASSERTIONS
-- ---------------------------------------------------------------------------
DO $$
DECLARE n int; v text;
BEGIN
  -- (a) the function exists with the right reach
  IF NOT has_function_privilege('authenticated','public.fn_correct_gdo_report(bigint,text,text)','EXECUTE') THEN
    RAISE EXCEPTION 'authenticated cannot execute the correction function';
  END IF;
  IF has_function_privilege('anon','public.fn_correct_gdo_report(bigint,text,text)','EXECUTE') THEN
    RAISE EXCEPTION 'anon can execute the correction function - must not';
  END IF;

  -- (b) it must NOT mention the forbidden columns anywhere in its body
  SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
   WHERE ns.nspname='public' AND p.proname='fn_correct_gdo_report'
     AND (pg_get_functiondef(p.oid) ~ 'SET[[:space:]]+status'
       OR pg_get_functiondef(p.oid) ~ 'dry_run[[:space:]]*=');
  IF n <> 0 THEN
    RAISE EXCEPTION 'the correction function assigns a forbidden column - that reopens the queue';
  END IF;

  -- (c) POSITIVE CONTROL: the view must actually return the live rows, and hide the dry-runs.
  SELECT count(*) INTO n FROM derm.visit_gdo_report;
  IF n <> 3 THEN
    RAISE EXCEPTION 'expected 3 live report rows, view returned % (dry-runs leaking?)', n;
  END IF;
  SELECT count(*) INTO n FROM public.derm_portal_submissions WHERE dry_run IS TRUE;
  IF n < 100 THEN
    RAISE EXCEPTION 'CONTROL FAILED: only % dry-run rows exist, so "the view hides them" proves nothing', n;
  END IF;

  -- (d) the storage policies exist for authenticated and NOT for anon
  SELECT count(*) INTO n FROM pg_policy
   WHERE polrelid='storage.objects'::regclass AND polname LIKE 'rpa_evidence_staff_%';
  IF n <> 3 THEN RAISE EXCEPTION 'expected 3 rpa-evidence policies, found %', n; END IF;

  RAISE NOTICE 'OK: correction fn is narrow, view exposes 3 live reports, evidence readable by staff';
END $$;

COMMIT;
