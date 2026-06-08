-- ============================================================================
-- 2026-06-08d — Self-maintain the "every client has >=1 location" invariant
-- ============================================================================
-- Stage 2 (2026-06-08b) materialized a default 'Main' location for every client that
-- existed THEN. Clients synced AFTERWARD (e.g. from Jobber) arrived with no location,
-- breaking the invariant and leaving their visits/invoices unattributable (caught:
-- client 476 synced 17:46, invoice 2406 unmapped). This adds a trigger so EVERY newly
-- inserted client auto-gets a 'Main' location — source-agnostic (webhook / scripts /
-- manual all covered) — and backfills the current stragglers.
--
-- SECURITY DEFINER so the location insert always succeeds regardless of the inserting
-- role's grants on client_locations (e.g. an app role). client_locations stays audited
-- (audit_client_locations captures the auto-insert). No new business table -> Rule 8 N/A
-- beyond the already-audited target.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.ensure_client_has_location() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.client_locations (client_id, name, status)
  VALUES (NEW.id, 'Main', 'active')
  ON CONFLICT (client_id, name) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_client_default_location ON public.clients;
CREATE TRIGGER trg_client_default_location
  AFTER INSERT ON public.clients
  FOR EACH ROW EXECUTE FUNCTION public.ensure_client_has_location();

-- Backfill any clients that currently lack a location (synced after 2026-06-08b).
INSERT INTO public.client_locations (client_id, name, status)
SELECT c.id, 'Main', 'active'
FROM public.clients c
WHERE NOT EXISTS (SELECT 1 FROM public.client_locations cl WHERE cl.client_id = c.id);

-- Verify: SELECT count(*) FROM clients c WHERE NOT EXISTS
--   (SELECT 1 FROM client_locations cl WHERE cl.client_id=c.id);  -- expect 0
