-- ============================================================================
-- 2026-06-08b — Location as the service grain (Stage 2)
-- ============================================================================
-- Per Fred 2026-06-08: the LOCATION (not the client) is the service unit — it owns
-- the manhole/GDO and the visits; reach the client THROUGH the location.
-- Decisions taken (AskUserQuestion 2026-06-08):
--   (1) a visit maps to MANY locations (one pump visit can service several manholes)
--       -> M:N via public.visit_locations (each manhole still gets its own DERM via manifest_visits).
--   (2) EVERY client gets >=1 location -> materialize a default 'Main' location for the
--       390 single-site clients (uniform 'locations' grain for FP / billing / DERM).
--
-- Audit (ADR 010):
--   * client_locations — already audited (audit_client_locations); the 390 'Main' inserts are captured.
--   * gdos             — NOT audited (sync table, opt-out as originally created); link updates not captured.
--   * visit_locations  — NEW, OPT-IN (human/FP-editable: techs tag which manholes a visit serviced).
--
-- Backfill assumption (flagged): for multi-location venues, each historical visit is linked to
-- every GDO-bearing location of that client (a venue grease service typically pumps all its traps).
-- FP/ops can correct per visit. Wynd (GDO-less tenant 'locations') is skipped — its 1 visit stays
-- unlinked pending GDO ingestion (D-track). 668 of 669 live visits get a location.
-- ============================================================================

-- 1) Materialize a default 'Main' location for every client that has none.
INSERT INTO public.client_locations (client_id, name, status)
SELECT c.id, 'Main', 'active'
FROM public.clients c
WHERE NOT EXISTS (SELECT 1 FROM public.client_locations cl WHERE cl.client_id = c.id);

-- 2) Bind the GDO for clients with exactly ONE active GDO and exactly ONE (the new Main) location,
--    and lift the GDO's service property onto the location.
UPDATE public.gdos g
SET client_location_id = cl.id
FROM public.client_locations cl
WHERE cl.client_id = g.client_id
  AND cl.name = 'Main'
  AND g.status = 'ACTIVE'
  AND g.client_location_id IS NULL
  AND (SELECT count(*) FROM public.client_locations x WHERE x.client_id = g.client_id) = 1
  AND (SELECT count(*) FROM public.gdos y WHERE y.client_id = g.client_id AND y.status = 'ACTIVE') = 1;

UPDATE public.client_locations cl
SET property_id = g.property_id
FROM public.gdos g
WHERE g.client_location_id = cl.id
  AND cl.name = 'Main'
  AND cl.property_id IS NULL
  AND g.property_id IS NOT NULL;

-- 3) Enforce the rule: one location has one GDO.
CREATE UNIQUE INDEX IF NOT EXISTS gdos_client_location_id_uniq
  ON public.gdos (client_location_id) WHERE client_location_id IS NOT NULL;

-- 4) visit_locations — M:N visit <-> location (a visit can service several manholes).
CREATE TABLE IF NOT EXISTS public.visit_locations (
  visit_id           bigint NOT NULL REFERENCES public.visits(id)           ON DELETE CASCADE,
  client_location_id bigint NOT NULL REFERENCES public.client_locations(id) ON DELETE CASCADE,
  created_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (visit_id, client_location_id)
);
CREATE INDEX IF NOT EXISTS idx_visit_locations_location ON public.visit_locations(client_location_id);

ALTER TABLE public.visit_locations ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.visit_locations TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.visit_locations TO authenticated;
GRANT ALL ON public.visit_locations TO service_role;
DROP POLICY IF EXISTS visit_locations_anon_read ON public.visit_locations;
CREATE POLICY visit_locations_anon_read    ON public.visit_locations FOR SELECT TO anon          USING (true);
DROP POLICY IF EXISTS visit_locations_auth_all ON public.visit_locations;
CREATE POLICY visit_locations_auth_all     ON public.visit_locations FOR ALL    TO authenticated USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS visit_locations_service_all ON public.visit_locations;
CREATE POLICY visit_locations_service_all  ON public.visit_locations FOR ALL    TO service_role  USING (true) WITH CHECK (true);

DROP TRIGGER IF EXISTS audit_visit_locations ON public.visit_locations;
CREATE TRIGGER audit_visit_locations AFTER INSERT OR UPDATE OR DELETE ON public.visit_locations
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- 5a) Backfill: single-location clients -> the one location (certain).
INSERT INTO public.visit_locations (visit_id, client_location_id)
SELECT v.id, cl.id
FROM public.visits v
JOIN public.client_locations cl ON cl.client_id = v.client_id
WHERE v.deleted_at IS NULL
  AND (SELECT count(*) FROM public.client_locations x WHERE x.client_id = v.client_id) = 1
ON CONFLICT (visit_id, client_location_id) DO NOTHING;

-- 5b) Backfill: multi-location clients -> every GDO-bearing location (venue-service assumption).
INSERT INTO public.visit_locations (visit_id, client_location_id)
SELECT v.id, cl.id
FROM public.visits v
JOIN public.client_locations cl ON cl.client_id = v.client_id
WHERE v.deleted_at IS NULL
  AND (SELECT count(*) FROM public.client_locations x WHERE x.client_id = v.client_id) > 1
  AND EXISTS (SELECT 1 FROM public.gdos g WHERE g.client_location_id = cl.id AND g.status = 'ACTIVE')
ON CONFLICT (visit_id, client_location_id) DO NOTHING;

-- Verify:
-- SELECT count(*) FROM public.client_locations;                          -- expect 404
-- SELECT count(*) FROM public.gdos WHERE client_location_id IS NOT NULL; -- expect 108 (9 + 99)
-- SELECT count(DISTINCT visit_id) FROM public.visit_locations;          -- expect 668
