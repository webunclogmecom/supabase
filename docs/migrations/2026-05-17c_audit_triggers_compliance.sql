-- 2026-05-17c_audit_triggers_compliance.sql
--
-- Audit Trail Layer 2 — compliance-grade triggers.
-- Tables: photo_classifications, derm_manifests, disposal_facilities.
--
-- These tables carry regulatory (DERM) or customer-visibility weight.
-- Every change needs "who/when" for compliance forensics.

BEGIN;

-- photo_classifications: Admin Review's primary surface. Every classification
-- decides whether a customer sees a photo on Field Portal.
DROP TRIGGER IF EXISTS audit_photo_classifications ON public.photo_classifications;
CREATE TRIGGER audit_photo_classifications
  AFTER INSERT OR UPDATE OR DELETE ON public.photo_classifications
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- derm_manifests: DERM regulatory data — white manifest #, disposal facility,
-- dates, attachment URLs. Customer-visible via Field Portal.
DROP TRIGGER IF EXISTS audit_derm_manifests ON public.derm_manifests;
CREATE TRIGGER audit_derm_manifests
  AFTER INSERT OR UPDATE OR DELETE ON public.derm_manifests
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- disposal_facilities: only 2 rows but regulatory reference data —
-- DERM cares which facility waste went to.
DROP TRIGGER IF EXISTS audit_disposal_facilities ON public.disposal_facilities;
CREATE TRIGGER audit_disposal_facilities
  AFTER INSERT OR UPDATE OR DELETE ON public.disposal_facilities
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

COMMIT;
