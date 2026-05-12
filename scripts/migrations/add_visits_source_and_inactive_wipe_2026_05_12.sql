-- ============================================================================
-- Migration: visits.source + INACTIVE wipe trigger + LS service type — 2026-05-12
-- TARGETS: Prod (wbasvhvvismukaqdnouk) AND Sandbox (ubtlwpcyntelgbykdatn)
-- ============================================================================
-- Why now:
--   This is the foundation for the Airtable sunset (May 2026). The recurring
--   visit schedule moves from Airtable's button-triggered automation to a
--   Supabase-native daily cron (`cron_generate_recurring_visits.js`). To
--   support that:
--
--   1. `visits.source` distinguishes who created each row in our DB so the
--      cron's idempotency check + webhook-jobber's merge logic can tell apart
--      'supabase_cron' (the cron's scheduled placeholder) from 'jobber' (a
--      real Jobber visit pulled by cron_jobber). The Supabase cron creates
--      rows that get PROMOTED (not replaced) when Jobber's version arrives.
--
--   2. The INACTIVE wipe trigger replicates the Airtable automation that
--      deletes a client's upcoming visits when they flip INACTIVE/PAUSED.
--      That logic moves to Supabase here, as a Postgres trigger — instant,
--      atomic, no race with the cron.
--
--   3. The `LS` (Lift Station) service type is a NEW category Fred is
--      introducing. Adding it to the allowed enum so the cron can write
--      LS service_configs rows when Yan creates them. No existing constraint
--      blocks unknown values today (no CHECK on service_type), but adding
--      one now both documents the rule and prevents typos.
--
-- After this:
--   - 593 existing visits all backfilled to source='jobber' (verified: all
--     have a Jobber entity_source_link).
--   - `LS` allowed on service_configs + visits.service_type.
--   - When `clients.status` flips to INACTIVE or PAUSED, all that client's
--     scheduled future visits are auto-deleted in the same transaction.
--   - The cron can safely write source='supabase_cron' rows; webhook-jobber's
--     handleVisit (separate change) will promote them when Jobber catches up.
--
-- Rollback:
--   DROP TRIGGER trg_clients_wipe_upcoming_on_inactive ON public.clients;
--   DROP FUNCTION trg_wipe_upcoming_on_inactive();
--   ALTER TABLE visits DROP COLUMN source;
--   (LS-related: there's no constraint to drop; LS just becomes an unused enum value.)
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. visits.source — track who created each row in our DB
-- ----------------------------------------------------------------------------
ALTER TABLE public.visits
  ADD COLUMN source text;

-- Backfill: all existing visits came from Jobber sync (verified pre-migration:
-- 593/593 have a Jobber entity_source_link). 247 also have Airtable ESLs
-- (dual-sourced visits where the Airtable mirror was independently created),
-- but the canonical origin is Jobber, so we tag them 'jobber'.
UPDATE public.visits SET source = 'jobber' WHERE source IS NULL;

ALTER TABLE public.visits
  ALTER COLUMN source SET NOT NULL,
  ALTER COLUMN source SET DEFAULT 'jobber',
  ADD CONSTRAINT visits_source_chk
    CHECK (source IN ('jobber','supabase_cron','airtable','manual','odoo'));

-- Index for the cron's idempotency check + webhook-jobber's merge query.
-- Partial index keeps it small (only 'supabase_cron' rows in the index).
CREATE INDEX idx_visits_source_cron_scheduled
  ON public.visits (client_id, service_type, visit_date)
  WHERE source = 'supabase_cron' AND visit_status = 'scheduled';

COMMENT ON COLUMN public.visits.source IS
  'Who created this row in our DB: jobber (cron_jobber pulled from Jobber API), supabase_cron (cron_generate_recurring_visits scheduled placeholder), airtable (legacy Airtable mirror sync — pre-2026-05 only), manual (hand-inserted via console), odoo (post-Odoo-cutover writes). When a supabase_cron row gets matched by an incoming Jobber visit, webhook-jobber PROMOTES it: UPDATE in place, source becomes ''jobber'', Jobber GID + entity_source_link attached. This avoids duplicates during the May-June 2026 Airtable+Jobber sunset transition.';

-- ----------------------------------------------------------------------------
-- 2. INACTIVE wipe trigger — replicates the Airtable automation we're sunsetting
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_wipe_upcoming_on_inactive()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Only fire on a transition INTO INACTIVE/PAUSED (not status updates within
  -- the same state, not transitions TO Recurring/ACTIVE).
  IF NEW.status IN ('INACTIVE','PAUSED')
     AND OLD.status NOT IN ('INACTIVE','PAUSED') THEN
    DELETE FROM public.visits
    WHERE client_id = NEW.id
      AND visit_status = 'scheduled'
      AND visit_date >= CURRENT_DATE;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_clients_wipe_upcoming_on_inactive ON public.clients;
CREATE TRIGGER trg_clients_wipe_upcoming_on_inactive
  BEFORE UPDATE OF status ON public.clients
  FOR EACH ROW
  WHEN (NEW.status IS DISTINCT FROM OLD.status)
  EXECUTE FUNCTION public.trg_wipe_upcoming_on_inactive();

COMMENT ON FUNCTION public.trg_wipe_upcoming_on_inactive() IS
  'When a client flips to INACTIVE or PAUSED, atomically delete all their scheduled future visits. Completed/skipped visits are NOT touched (historical record). Replaces the legacy Airtable automation that did the same thing button-by-button.';

-- ----------------------------------------------------------------------------
-- 3. LS (Lift Station) service type — net-new category Fred is introducing
-- ----------------------------------------------------------------------------
-- No CHECK constraint exists today on service_configs.service_type or
-- visits.service_type. We add one now to enforce the allowed set + prevent
-- typos. Current values in service_configs: GT, CL, WD. Adding LS.
-- Note: 'WD' is "Warranty of drainage" and 'Gray Water pumping' maps to GT
-- per Fred's mapping (handled in the cron, not the schema).

ALTER TABLE public.service_configs
  ADD CONSTRAINT service_configs_service_type_chk
    CHECK (service_type IN ('GT','CL','WD','LS'));

ALTER TABLE public.visits
  ADD CONSTRAINT visits_service_type_chk
    CHECK (service_type IS NULL OR service_type IN ('GT','CL','WD','LS'));
    -- NULL allowed on visits because pre-2026 historical rows have NULL
    -- service_type (per CLAUDE.md "Pre-2026 NULL service_type" gotcha).

COMMIT;

-- ============================================================================
-- Verification queries (run after COMMIT):
--
-- 1. All visits have source set:
--    SELECT source, COUNT(*) FROM visits GROUP BY source;
--    Expected: jobber=593, no other rows.
--
-- 2. Trigger exists and fires:
--    SELECT tgname FROM pg_trigger WHERE tgrelid='public.clients'::regclass;
--    Expected: includes trg_clients_wipe_upcoming_on_inactive.
--
-- 3. Test the wipe trigger on a sandbox client (DO NOT run on Prod with a
--    real client; pick an already-INACTIVE one):
--    BEGIN;
--      UPDATE clients SET status='Recuring' WHERE id=<some_inactive>;
--      INSERT INTO visits (client_id, visit_date, visit_status, source)
--        VALUES (<that_id>, CURRENT_DATE+10, 'scheduled', 'supabase_cron');
--      UPDATE clients SET status='INACTIVE' WHERE id=<that_id>;
--      SELECT * FROM visits WHERE client_id=<that_id> AND visit_date >= CURRENT_DATE;
--      -- Should be 0 rows.
--    ROLLBACK;
--
-- 4. LS service type now allowed:
--    INSERT INTO service_configs (client_id, service_type, frequency_days)
--      VALUES (<some_client>, 'LS', 30);
--    -- Should succeed.
-- ============================================================================
