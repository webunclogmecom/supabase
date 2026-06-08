-- ============================================================================
-- 2026-06-08e — Seed visit_locations on EVERY visit-insert path (DB trigger)
-- ============================================================================
-- The 2026-06-08b webhook-jobber handleVisit change seeds visit_locations, but the
-- audit found 4 OTHER paths that INSERT visits and skip it:
--   * Calendar Lovable app (source='visit-calendar') — now the visit source of truth
--   * cron_generate_recurring_visits.js, generate_service_agreement_visits.js,
--     reconcile_jobber_visits.js — direct REST inserts
-- Those visits would land unattributed to any manhole -> invisible to ops.invoice_locations,
-- per-location billing, and per-manhole DERM. This adds an AFTER INSERT trigger on visits so
-- the manhole(s) are seeded source-agnostically (single-loc client -> its one location;
-- multi-loc -> its ACTIVE-GDO manholes; ONLY when the visit has none, so FP/ops/webhook tags
-- are preserved). The handleVisit block stays (harmless + idempotent; it also covers the
-- update/promote path the AFTER-INSERT trigger doesn't fire on).
--
-- SECURITY DEFINER so the seed succeeds even when the inserting role (e.g. the Calendar app's
-- anon/authenticated) lacks INSERT on visit_locations. visit_locations stays audited.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.seed_visit_locations() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE loc_count int;
BEGIN
  IF NEW.client_id IS NULL THEN RETURN NEW; END IF;
  IF EXISTS (SELECT 1 FROM public.visit_locations WHERE visit_id = NEW.id) THEN RETURN NEW; END IF;
  SELECT count(*) INTO loc_count FROM public.client_locations WHERE client_id = NEW.client_id;
  IF loc_count = 1 THEN
    INSERT INTO public.visit_locations (visit_id, client_location_id)
    SELECT NEW.id, cl.id FROM public.client_locations cl WHERE cl.client_id = NEW.client_id
    ON CONFLICT DO NOTHING;
  ELSIF loc_count > 1 THEN
    INSERT INTO public.visit_locations (visit_id, client_location_id)
    SELECT NEW.id, cl.id FROM public.client_locations cl
    WHERE cl.client_id = NEW.client_id
      AND EXISTS (SELECT 1 FROM public.gdos g WHERE g.client_location_id = cl.id AND g.status = 'ACTIVE')
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_visit_default_locations ON public.visits;
CREATE TRIGGER trg_visit_default_locations
  AFTER INSERT ON public.visits
  FOR EACH ROW EXECUTE FUNCTION public.seed_visit_locations();

-- Backfill any visits created since 2026-06-08b that still lack a location (e.g. Calendar/cron).
INSERT INTO public.visit_locations (visit_id, client_location_id)
SELECT v.id, cl.id
FROM public.visits v
JOIN public.client_locations cl ON cl.client_id = v.client_id
WHERE v.deleted_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM public.visit_locations vl WHERE vl.visit_id = v.id)
  AND (SELECT count(*) FROM public.client_locations x WHERE x.client_id = v.client_id) = 1
ON CONFLICT DO NOTHING;

INSERT INTO public.visit_locations (visit_id, client_location_id)
SELECT v.id, cl.id
FROM public.visits v
JOIN public.client_locations cl ON cl.client_id = v.client_id
WHERE v.deleted_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM public.visit_locations vl WHERE vl.visit_id = v.id)
  AND (SELECT count(*) FROM public.client_locations x WHERE x.client_id = v.client_id) > 1
  AND EXISTS (SELECT 1 FROM public.gdos g WHERE g.client_location_id = cl.id AND g.status = 'ACTIVE')
ON CONFLICT DO NOTHING;

-- Verify: SELECT count(*) FROM visits v WHERE v.deleted_at IS NULL
--   AND NOT EXISTS (SELECT 1 FROM visit_locations vl WHERE vl.visit_id=v.id);  -- only Wynd/045-NU (no ACTIVE-GDO location)
