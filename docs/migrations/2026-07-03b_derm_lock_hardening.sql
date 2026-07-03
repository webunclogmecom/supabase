-- Migration: 2026-07-03b_derm_lock_hardening.sql
-- Author: Claude (Supabase session)
-- Follow-up to 2026-07-03_derm_required_manual_lock.sql after an adversarial smoke-test review.
-- No must-fix defects were found; these are robustness + visibility hardenings.
--
-- 1) fn_lock_manual_derm_required hardening:
--    (a) EXCEPTION guard around the request.headers ::jsonb cast — a malformed GUC now
--        degrades to "not derm-tracker" instead of aborting the whole UPDATE. This is what
--        audit.log_change already does; the original migration comment claimed parity but the
--        guard was missing.
--    (b) case-insensitive origin match (ILIKE) — robustness against an uppercased Origin host.
--    (c) lock on ANY derm-tracker write that targets derm_required, even a same-value re-click.
--        The original trigger's WHEN (NEW.derm_required IS DISTINCT FROM OLD.derm_required) gate
--        skipped a human "not required" re-click on an already-false visit, leaving it UNLOCKED
--        (so a later Jobber line-item change could let the cron re-promote it). The trigger now
--        fires on BEFORE UPDATE OF derm_required (column targeted) and the function decides:
--          - derm-tracker write            -> lock (value passes through, human always wins)
--          - other writer + row is locked + value would change -> revert to the human value
--        (0 live/historical victims of the old gap; this closes it at the DB level regardless.)
--
-- 2) ops.v_derm_human_override_conflict — a review surface. The lock lets a human "DERM not
--    required" override the auto pumping-line-item verdict (fn_visit_requires_derm). That is the
--    fix's deliberate premise, but it hides such visits from every missing-docs surface, which
--    contradicts ADR-018's "pumping verdict is a monotonic compliance floor". This view lists
--    exactly those conflicts (locked not-required BUT line items say pumping) so Yannick can
--    confirm each human decision rather than trusting it blindly. It changes NO behavior.
--
-- Rollback: restore the fn/trigger from 2026-07-03_derm_required_manual_lock.sql;
--           DROP VIEW ops.v_derm_human_override_conflict;

BEGIN;

-- 1) hardened lock function -------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_lock_manual_derm_required()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_headers jsonb;
  v_is_derm boolean;
BEGIN
  -- Detect the writing app like audit.log_change does (PostgREST request headers),
  -- with the same defensive cast so a malformed GUC never aborts the write.
  BEGIN
    v_headers := NULLIF(current_setting('request.headers', true), '')::jsonb;
  EXCEPTION WHEN others THEN
    v_headers := NULL;
  END;
  v_is_derm := (
        NULLIF(v_headers ->> 'x-app-source', '') = 'derm-tracker'
     OR (v_headers ->> 'origin') ILIKE '%derm.unclogme.app%'
  );

  IF v_is_derm THEN
    -- deliberate human decision (any derm-tracker derm_required write, even same-value) -> sticky
    NEW.derm_required_locked := true;
  ELSIF OLD.derm_required_locked IS TRUE
        AND NEW.derm_required IS DISTINCT FROM OLD.derm_required THEN
    -- automated writer tried to change a human-locked value -> preserve the human value
    NEW.derm_required := OLD.derm_required;
  END IF;

  RETURN NEW;
END;
$$;

-- trigger now fires whenever derm_required is targeted (no value-change WHEN gate),
-- so a same-value human re-click still locks.
DROP TRIGGER IF EXISTS trg_derm_required_lock ON public.visits;
CREATE TRIGGER trg_derm_required_lock
  BEFORE UPDATE OF derm_required ON public.visits
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_lock_manual_derm_required();

-- 2) human-override compliance review surface -------------------------------
CREATE OR REPLACE VIEW ops.v_derm_human_override_conflict AS
SELECT
  v.id                                                            AS visit_id,
  c.client_code,
  c.name                                                         AS client_name,
  v.visit_date,
  v.visit_status,
  (now() AT TIME ZONE 'America/New_York')::date - v.visit_date   AS age_days,
  EXISTS (
    SELECT 1 FROM public.manifest_visits mv
    JOIN public.derm_manifests dm ON dm.id = mv.manifest_id
    WHERE mv.visit_id = v.id AND dm.deleted_at IS NULL
  )                                                              AS has_manifest,
  v.derm_required,
  v.derm_required_locked
FROM public.visits v
LEFT JOIN public.clients c ON c.id = v.client_id
WHERE v.deleted_at IS NULL
  AND v.derm_required_locked = true
  AND v.derm_required = false
  AND public.fn_visit_requires_derm(v.id) = true      -- auto-verdict says pumping (needs DERM)
ORDER BY (now() AT TIME ZONE 'America/New_York')::date - v.visit_date DESC;

COMMENT ON VIEW ops.v_derm_human_override_conflict IS
  'Compliance review surface (2026-07-03): visits a human locked as "DERM not required" whose '
  'line items nonetheless classify as pumping (fn_visit_requires_derm=true). These are hidden '
  'from all missing-docs surfaces by design (human overrides auto) — review each to confirm the '
  '"not required" call was correct. Clear derm_required_locked + set derm_required=true to re-require.';

COMMIT;
