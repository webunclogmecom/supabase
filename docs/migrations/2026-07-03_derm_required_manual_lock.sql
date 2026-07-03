-- Migration: 2026-07-03_derm_required_manual_lock.sql
-- Author: Claude (Supabase session)
-- Ticket/Reason: Yannick (Slack) — "DERM visits missing documents re-appearing".
--
-- ROOT CAUSE
--   public.visits.derm_required carries TWO conflicting meanings in one column:
--     (a) the AUTO line-item classification  (fn_visit_requires_derm → TRUE when the
--         job/invoice has pumping line items), and
--     (b) a HUMAN judgement — Diego/Yannick click "DERM not required" in the DERM
--         Tracker app, which writes derm_required = false.
--   The nightly cron `rederive_visits_derm_required` (07:20 UTC) is monotonic UP-only:
--   its guard `derm_required IS NOT TRUE` treats a human FALSE identically to an
--   unknown NULL and re-promotes it to TRUE whenever the classifier says "pumping".
--   So every night the human "not required" decision is overwritten and the visit
--   re-appears in the DERM Tracker "Missing Docs" list.
--
-- FIX (permanent, code-path-independent, no app change, no consumer-view rewrite)
--   1. Add an additive lock column `derm_required_locked`.
--   2. BEFORE-UPDATE trigger `trg_derm_required_lock`:
--        - a write from the DERM Tracker (detected by the SAME request-header origin
--          the audit system uses: x-app-source='derm-tracker' or origin derm.unclogme.app)
--          that changes derm_required is a deliberate human decision → set locked = true.
--        - any OTHER writer (cron / handleVisit / raw SQL) that tries to change a
--          locked value is reverted to the human value → the lock is enforced no matter
--          which code path attempts the override.
--   3. Belt-and-suspenders: add `AND derm_required_locked IS NOT TRUE` to the two
--      auto writers so they don't even attempt a locked row (no wasted audit churn).
--   `derm_required` stays the single effective value — the 8 consumer views
--   (derm.visits, ops.v_derm_compliance, ops.v_calendar_visit, customer.work_orders,
--   manifest_pickable_visits, …) need no change.
--
-- RESTORE of the human decisions the cron already flipped is a SEPARATE data op
--   (scripts/probes/derm_restore_locked_not_required.js) — not in this migration.
--
-- Rollback: DROP TRIGGER trg_derm_required_lock ON public.visits;
--           DROP FUNCTION public.fn_lock_manual_derm_required();
--           ALTER TABLE public.visits DROP COLUMN derm_required_locked;
--           (and revert the two functions to their pre-guard bodies).

BEGIN;

-- 1) additive lock column ---------------------------------------------------
ALTER TABLE public.visits
  ADD COLUMN IF NOT EXISTS derm_required_locked boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.visits.derm_required_locked IS
  'TRUE = a human deliberately set derm_required via the DERM Tracker app ("DERM not '
  'required"/"required"). The nightly re-derive (rederive_visits_derm_required), '
  'set_visit_derm_required, handleVisit and every other automated writer must NOT '
  'override it. Auto-set by trigger trg_derm_required_lock on DERM-Tracker writes and '
  'enforced defensively there for any non-DERM-Tracker writer. To hand a visit back to '
  'auto-classification, set derm_required_locked = false explicitly.';

-- 2) lock trigger fn --------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_lock_manual_derm_required()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_headers jsonb;
  v_is_derm boolean;
BEGIN
  -- Detect the writing app exactly like audit.log_change does (PostgREST request headers).
  -- pg_cron / raw SQL have no request.headers → v_headers is NULL → v_is_derm is false.
  v_headers := NULLIF(current_setting('request.headers', true), '')::jsonb;
  v_is_derm := (
        NULLIF(v_headers ->> 'x-app-source', '') = 'derm-tracker'
     OR (v_headers ->> 'origin') LIKE '%derm.unclogme.app%'
  );

  IF v_is_derm THEN
    -- deliberate human decision → make it sticky
    NEW.derm_required_locked := true;
  ELSIF OLD.derm_required_locked IS TRUE THEN
    -- an automated writer tried to change a human-locked value → preserve the human value
    NEW.derm_required := OLD.derm_required;
  END IF;

  RETURN NEW;
END;
$$;

-- 3) trigger: only when derm_required actually changes -----------------------
DROP TRIGGER IF EXISTS trg_derm_required_lock ON public.visits;
CREATE TRIGGER trg_derm_required_lock
  BEFORE UPDATE OF derm_required ON public.visits
  FOR EACH ROW
  WHEN (NEW.derm_required IS DISTINCT FROM OLD.derm_required)
  EXECUTE FUNCTION public.fn_lock_manual_derm_required();

-- 4) auto writers skip locked rows (belt-and-suspenders) --------------------
CREATE OR REPLACE FUNCTION public.rederive_visits_derm_required()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE n integer;
BEGIN
  WITH d AS (
    SELECT id, public.fn_visit_requires_derm(id) AS derived
    FROM public.visits
    WHERE deleted_at IS NULL
  )
  UPDATE public.visits v
     SET derm_required = d.derived
    FROM d
   WHERE d.id = v.id
     AND d.derived IS NOT NULL
     AND v.derm_required IS NOT TRUE
     AND v.derm_required IS DISTINCT FROM d.derived
     AND v.derm_required_locked IS NOT TRUE;   -- respect human "not required" lock
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_visit_derm_required(p_visit_id bigint)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
DECLARE v_d boolean;
BEGIN
  v_d := public.fn_visit_requires_derm(p_visit_id);
  IF v_d IS NOT NULL THEN
    UPDATE public.visits
       SET derm_required = v_d
     WHERE id = p_visit_id
       AND derm_required IS NOT TRUE              -- never demote a known TRUE
       AND derm_required IS DISTINCT FROM v_d     -- idempotent (no audit/updated_at churn)
       AND derm_required_locked IS NOT TRUE;      -- respect human "not required" lock
  END IF;
  RETURN v_d;
END;
$function$;

COMMIT;
