-- 2026-05-22d_gdo_compliance_trigger.sql
--
-- Event-driven half of `gdo_compliance_sentinel` (weekly cron landed
-- 2026-05-22 in #viktor-supabase Slack ts 1779410917.319289).
--
-- Fires `pg_notify('gdo_compliance_alert', ...)` whenever a GT visit lands
-- on a client that lacks an active/expired GDO in Miami-Dade. Catches the
-- "we just dispatched a truck to an unpermitted address" risk window same-
-- day instead of waiting for the weekly Mon-8am sweep.
--
-- Author: drafted by Viktor (Slack ts 1779412284.x), reviewed by Fred,
-- iterated 3 revs (v1 had wrong status enum, v2 missed visits.derm_required,
-- v2 also mis-referenced clients.derm_required which doesn't exist).
--
-- 3NF check (Rule 2): pure read function + trigger, no schema changes,
-- no new columns. N/A.
--
-- Audit (Rule 8): function does NOT write any rows — only emits pg_notify.
-- No audit opt-in needed. The visits table audit_visits trigger is
-- unaffected; this trigger fires AFTER and is independent.
--
-- Source-of-truth (Rule 4): reads canonical Jobber-sourced visits + Prod
-- gdos. Doesn't introduce any new source.
--
-- RLS / permissions: SECURITY DEFINER so the trigger can SELECT from
-- properties + gdos regardless of the caller's RLS context (webhook
-- inserts as service-role today, but if Lovable apps ever INSERT visits
-- the trigger still needs full read access).
--
-- Idempotent (Rule 5): CREATE OR REPLACE on the function; the trigger
-- uses CREATE which would conflict on re-run — drop-and-recreate guarded
-- below so the file is safely re-runnable.
--
-- Downstream listener (NOT in this migration): an Edge Function or
-- cron-tail script that LISTEN's on 'gdo_compliance_alert' and posts to
-- #viktor-supabase. Wiring TBD; weekly batch (already live) covers the
-- gap until then.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_check_gdo_on_visit()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_county  TEXT;
  v_has_gdo BOOLEAN;
BEGIN
  -- Only care about GT visits
  IF NEW.service_type != 'GT' THEN
    RETURN NEW;
  END IF;

  -- Per-visit opt-out (visits.derm_required, 3-state:
  --   NULL  = default-true for GT
  --   TRUE  = explicit opt-in
  --   FALSE = ops marked "not required" via DERM Tracker)
  IF NEW.derm_required IS FALSE THEN
    RETURN NEW;
  END IF;

  -- Check county (Dade only for v1)
  SELECT p.county INTO v_county
  FROM properties p
  WHERE p.client_id = NEW.client_id
    AND p.is_primary = true
  LIMIT 1;

  IF v_county IS DISTINCT FROM 'Dade' THEN
    RETURN NEW;
  END IF;

  -- Check gdos table (ACTIVE + EXPIRED both count as "has a permit",
  -- since EXPIRED still ties to the physical trap, just needs renewal)
  SELECT EXISTS(
    SELECT 1 FROM gdos g
    WHERE g.client_id = NEW.client_id
      AND g.status IN ('ACTIVE', 'EXPIRED')
  ) INTO v_has_gdo;

  -- Fire alert if no GDO on file
  IF NOT v_has_gdo THEN
    PERFORM pg_notify(
      'gdo_compliance_alert',
      json_build_object(
        'client_id',      NEW.client_id,
        'visit_id',       NEW.id,
        'visit_date',     NEW.visit_date,
        'derm_required',  NEW.derm_required,
        'event',          'gt_visit_no_gdo'
      )::text
    );
  END IF;

  RETURN NEW;
END;
$$;

-- Re-runnable: drop the trigger first if it exists.
DROP TRIGGER IF EXISTS trg_gdo_compliance_check ON public.visits;

CREATE TRIGGER trg_gdo_compliance_check
  AFTER INSERT OR UPDATE OF service_type
  ON public.visits
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_check_gdo_on_visit();

COMMENT ON FUNCTION public.fn_check_gdo_on_visit() IS
  'Fires pg_notify(gdo_compliance_alert) on GT visits in Dade where the client has no ACTIVE/EXPIRED GDO. Honors visits.derm_required=false opt-out. v3 (2026-05-22). See docs/migrations/2026-05-22d header.';

COMMIT;

-- Verification:
-- 1. Insert a fake GT visit for a client with no GDO in Dade — should fire
--    pg_notify (visible via LISTEN gdo_compliance_alert in a separate session).
-- 2. Insert with derm_required=false — should NOT fire.
-- 3. Insert with service_type='CL' — should NOT fire.
-- 4. Insert for a client whose property.county='Broward' — should NOT fire.
