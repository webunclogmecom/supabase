-- 2026-07-04_stamp_sheet_status_audit_optin.sql
-- Protocol-audit finding F1: derm.stamp_sheet_status records a HUMAN decision
-- ("this sheet is completed/verified") that gates compliance exports and, later,
-- FP redaction — per Rule 8's default (human-editable fields -> opt-IN) it must
-- be audited. Also adds the standard updated_at trigger (Rule 7: trigger-managed).
-- derm.address_row_map already has both (audit_address_row_map +
-- trg_address_row_map_updated_at); this brings stamp_sheet_status to parity.

BEGIN;

CREATE TRIGGER audit_stamp_sheet_status
AFTER INSERT OR UPDATE OR DELETE ON derm.stamp_sheet_status
FOR EACH ROW EXECUTE FUNCTION audit.log_change();

CREATE TRIGGER trg_stamp_sheet_status_updated_at
BEFORE UPDATE ON derm.stamp_sheet_status
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

COMMIT;
