-- ============================================================================
-- 2026-08-19  Let a MANUAL filing exist on a pre-cutoff visit
-- ============================================================================
-- 🛑 THIS AMENDS AN EXISTING SAFETY RAIL. Read the reasoning before changing it again.
--
-- trg_aa_rpa_submission_dry_run_guard enforces a strict biconditional:
--     dry_run MUST equal (visit_date < rpa_launch_cutoff())
-- i.e. a visit before 2026-07-21 may ONLY carry dry-run rows, and a visit on/after it may
-- only carry live ones. Its purpose is the BOT's rollout: it stops John's RPA filing for
-- real against the historical era it was never meant to touch.
--
-- THE COLLISION. Fred asked for a way to record a report a PERSON filed by hand. All 29
-- visits that need it are pre-cutoff (measured: 29 before, 5 after, 0 of the 5 unfiled).
-- A human filing is not a dry run, so the guard rejected every one of them and the feature
-- would have shipped covering zero of its own use case. The probe caught this before any
-- UI existed:  "dry_run=f disagrees with visit 5786 service-date classification".
--
-- WHY EXEMPTING MANUAL ROWS IS SAFE, and this is the load-bearing argument:
--   1. v_derm_portal_queue already begins `WHERE visit_date >= rpa_launch_cutoff()`. A
--      pre-cutoff visit is excluded from the bot's queue BY DATE, whatever rows it carries.
--      So a manual row on one of the 29 is INERT with respect to the bot - it cannot
--      suppress a filing that was never going to happen, and cannot trigger one either.
--   2. The bot cannot produce a row this exemption admits. run_id 'manual-%' is created
--      ONLY by fn_record_manual_gdo_report; the RPA's run ids have never used that prefix
--      (measured: 0 rows before this feature).
--   3. That function is SECURITY DEFINER, granted to service_role only, and refuses
--      anything without a confirmation number, an uploaded screenshot at the RLS-sanctioned
--      path, a completed visit, a code-27 line item, and no existing filing.
--   4. The guard still applies in FULL to every non-manual row, so the bot's own rollout
--      protection is unchanged. Proven by the probe: a bot-shaped row on a pre-cutoff visit
--      is still rejected.
--
-- ⚠ WHAT THIS DOES NOT DO: it does not move rpa_launch_cutoff(), and must not be used as a
-- way to. Moving the cutoff would release the bot onto 29 historical visits and file them
-- with Miami-Dade a second time.
--
-- Body copied from pg_get_functiondef and extended; the original branch is byte-identical
-- apart from the added exemption.
-- ============================================================================

BEGIN;
SET LOCAL search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION public.trg_rpa_submission_dry_run_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE v_vdate date;
BEGIN
  -- A manual filing recorded by a person is outside this guard's scope. It is marked by a
  -- run_id the bot never uses, and pre-cutoff visits are excluded from the bot's queue by
  -- date regardless, so such a row cannot change what the bot does. See the migration header.
  IF NEW.run_id LIKE 'manual-%' AND NEW.dry_run IS NOT TRUE THEN
    RETURN NEW;
  END IF;

  SELECT visit_date INTO v_vdate FROM public.visits WHERE id = NEW.visit_id;
  IF v_vdate IS NOT NULL AND NEW.dry_run <> (v_vdate < public.rpa_launch_cutoff()) THEN
    RAISE EXCEPTION 'dry_run=% disagrees with visit % service-date classification (visit_date %)',
      NEW.dry_run, NEW.visit_id, v_vdate;
  END IF;
  RETURN NEW;
END $function$;

COMMIT;
