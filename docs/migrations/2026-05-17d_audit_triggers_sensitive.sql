-- 2026-05-17d_audit_triggers_sensitive.sql
--
-- Audit Trail Layer 2 — sensitive-data triggers.
-- Tables: vehicles, employees, webhook_tokens.
--
-- These tables contain payroll, fleet compliance, or security-sensitive data.
-- Changes are rare but must be forensically traceable.

BEGIN;

-- vehicles: fleet decal numbers, license plates, tank capacities — all
-- used in DERM filings.
DROP TRIGGER IF EXISTS audit_vehicles ON public.vehicles;
CREATE TRIGGER audit_vehicles
  AFTER INSERT OR UPDATE OR DELETE ON public.vehicles
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- employees: driver names, license info, employment status — payroll-adjacent.
DROP TRIGGER IF EXISTS audit_employees ON public.employees;
CREATE TRIGGER audit_employees
  AFTER INSERT OR UPDATE OR DELETE ON public.employees
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- webhook_tokens: holds OAuth access_token + client_secret. Every change is
-- security-sensitive. Token refreshes will create regular audit rows — that's
-- the point: forensic visibility into auth churn.
DROP TRIGGER IF EXISTS audit_webhook_tokens ON public.webhook_tokens;
CREATE TRIGGER audit_webhook_tokens
  AFTER INSERT OR UPDATE OR DELETE ON public.webhook_tokens
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

COMMIT;
