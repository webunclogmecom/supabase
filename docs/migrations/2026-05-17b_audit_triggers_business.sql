-- 2026-05-17b_audit_triggers_business.sql
--
-- Audit Trail Layer 2 — business-data triggers.
-- Tables: clients, service_configs, properties, visits.
--
-- Per ADR 010 audit-trail standing rule, these tables carry human-editable
-- fields where "who/when changed this?" is operationally important.
--
-- All AFTER triggers, row-level, fire on INSERT/UPDATE/DELETE. The function
-- (audit.log_change, defined in migration 17a) handles the rest including
-- skipping no-op updates (only updated_at changed).

BEGIN;

-- clients: slug + status changes break Field Portal QR access; legal-name
-- changes are billing-relevant. Source-of-truth is Jobber, but Admin Review
-- + manual edits go through here too.
DROP TRIGGER IF EXISTS audit_clients ON public.clients;
CREATE TRIGGER audit_clients
  AFTER INSERT OR UPDATE OR DELETE ON public.clients
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- service_configs: price + frequency = revenue + cadence. Airtable sync
-- writes here regularly; need to know when/what changed.
DROP TRIGGER IF EXISTS audit_service_configs ON public.service_configs;
CREATE TRIGGER audit_service_configs
  AFTER INSERT OR UPDATE OR DELETE ON public.service_configs
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- properties: manhole defaults, access notes, address (Field Portal display).
-- Manhole writes from Admin Review go through here.
DROP TRIGGER IF EXISTS audit_properties ON public.properties;
CREATE TRIGGER audit_properties
  AFTER INSERT OR UPDATE OR DELETE ON public.properties
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- visits: manhole_count, visit_status, completed_at (Admin Review writes).
-- The function already skips no-op UPDATEs (only updated_at changed), so
-- the high-volume Jobber-sync churn won't bloat the log.
DROP TRIGGER IF EXISTS audit_visits ON public.visits;
CREATE TRIGGER audit_visits
  AFTER INSERT OR UPDATE OR DELETE ON public.visits
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

COMMIT;
